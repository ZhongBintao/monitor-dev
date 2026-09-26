import Foundation
import CoreFoundation

// MARK: - MultitouchSupport 私有框架绑定（最小接口面，实验性）
//
// 本桥的接口事实（函数原型、MTTouch 结构布局、状态机取值）取自三个
// 成熟开源实现，仅作接口互操作之用：
//   - calftrail/Touch（TouchSynthesis/MultitouchSupport.h，Nathan Vander Wilt，2010）
//     —— MTTouch 布局与函数原型的经典参考；
//   - mhuusko5/M5MultitouchSupport —— Swift 绑定模式；
//   - Kyome22/OpenMultitouchSupport（MIT）—— 状态机口径与归一化坐标方向。
// MultitouchSupport.framework 为 macOS 私有框架，接口十余年稳定；
// 通过链接标志引入（-F /System/Library/PrivateFrameworks）。
//
// 隐私红线：本层只向聚合层输出「making/touching 状态触点的归一化坐标」，
// 不保存、不打印任何原始触点流、轨迹序列或设备标识。

// MARK: C 类型转写（布局与 calftrail 头文件逐字段一致）

/// `typedef struct MTDevice *MTDeviceRef`（不透明设备指针）。
public typealias MTDeviceRef = OpaquePointer

struct MTPointC {
    var x: Float
    var y: Float
}

struct MTVectorC {
    var position: MTPointC
    var velocity: MTPointC
}

/// MTTouch 内存布局（96 字节，全标量字段）：
/// Int32@0 / Double@8 / Int32@16 / UInt32@20 / Int32@24 / Int32@28 /
/// MTVector@32(16B) / Float@48 / Int32@52 / Float@56,60,64 /
/// MTVector@68(16B) / Int32@84,88 / Float@92。
struct MTTouchC {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVectorC
    var zTotal: Float
    var field9: Int32
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVectorC
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

/// 触点状态机（MTTouchState）：3(making)/4(touching) = 接触中；
/// 5(breaking)/6(lingering)/7(outOfRange) = 离开信号；
/// 1(startInRange)/2(hover) = 接近未触。帧语义下只派发接触中手指，
/// 「离开」由帧缺席表达（对齐 Kyome22 OMS touchDataStream 的全量口径）。
enum MTTouchStateC {
    static let making: UInt32 = 3
    static let touching: UInt32 = 4
    static let breaking: UInt32 = 5
    static let lingering: UInt32 = 6
    static let outOfRange: UInt32 = 7
}

/// 单个触点样本（一帧内接触中的手指，坐标已翻转为 0=上）。
public struct TouchSample: Sendable {
    public let fingerID: Int32
    public let x: Double           // 归一化 0–1，左→右
    public let y: Double           // 归一化 0–1，上→下（已由 MT 左下原点翻转）
    public let pressure: Double    // 电容总量 0–1（zTotal，按帧）
    public let majorAxis: Double   // 接触椭圆长轴（mm）
    public let minorAxis: Double   // 接触椭圆短轴（mm）
    public let angle: Double       // 椭圆旋转角（弧度）
}

/// 一帧内的全部有效触点（已过手掌过滤）。
/// 消费端以「帧全量替换」同步状态：本帧没有的手指即已离开——
/// 触点集合与物理接触严格一致，不依赖离开事件（对齐
/// Kyome22 OMS Demo 的 touchDataStream 全量替换用法）。
public struct TouchFrame: Sendable {
    public let touches: [TouchSample]
}

/// MTRegisterContactFrameCallback 的回调签名。
/// MTTouch 数组以 raw pointer 传递（Swift 自定义 struct 不能直接出现在
/// @convention(c) 签名里），内部按 MemoryLayout<MTTouchC>.stride 读取——
/// 该布局为全标量字段，与 C 侧逐字段对齐（start 时有断言校验）。
typealias MTFrameCallbackC = @convention(c) (MTDeviceRef, UnsafeMutableRawPointer, Int, Double, Int) -> Void

// MARK: 私有框架符号绑定（链接期由 MultitouchSupport.framework 解析）

@_silgen_name("MTDeviceIsAvailable")
func MTDeviceIsAvailable() -> Bool

@_silgen_name("MTDeviceCreateList")
func MTDeviceCreateList() -> CFArray?

@_silgen_name("MTDeviceRelease")
func MTDeviceRelease(_ device: MTDeviceRef)

@_silgen_name("MTDeviceStart")
func MTDeviceStart(_ device: MTDeviceRef, _ options: Int32) -> Int32

@_silgen_name("MTDeviceStop")
func MTDeviceStop(_ device: MTDeviceRef) -> Int32

@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTFrameCallbackC)

// MARK: 全局回调路由

/// MTRegisterContactFrameCallback 不带 refcon（C 函数指针无上下文），
/// 经此全局入口路由到当前监听器。
private let callbackRouteLock = NSLock()
private nonisolated(unsafe) var activeTouchHandler: TouchpointMonitor.TouchHandler?

/// 诊断探针：INPUTSCAPE_DEBUG_TOUCH=1 时把触点样本（坐标/压力/椭圆轴）
/// 追加到 /tmp/inputscape-events.log，用于核对 MTTouch 布局、坐标方向、
/// 手指压力值域与手掌判定阈值。只记录字段数值。
private let debugTouchSamples =
    ProcessInfo.processInfo.environment["INPUTSCAPE_DEBUG_TOUCH"] == "1"
private nonisolated(unsafe) var debugSampleCount = 0
private let debugSampleLock = NSLock()

// MARK: 近窗接触压力环（校准判定 override 的数据源）

/// MT 回调线程写入、主线程读取的最近接触压力样本（时间戳 + zTotal）。
/// 仅供点击瞬间的校准判定查询（近窗最大值），不落盘、不进任何统计。
private let pressureRingLock = NSLock()
private nonisolated(unsafe) var pressureRing: [(at: Date, pressure: Double)] = []

private func recordPressureSamples(_ contacts: [TouchSample]) {
    guard !contacts.isEmpty else { return }
    let now = Date()
    pressureRingLock.lock()
    for sample in contacts where sample.pressure > 0 {
        pressureRing.append((now, sample.pressure))
    }
    if pressureRing.count > 256 {
        pressureRing.removeFirst(pressureRing.count - 256)
    }
    pressureRingLock.unlock()
}

/// C 回调入口：每帧组装全量触点列表（方向翻转 + 手掌过滤）后派发。
/// MT 内部线程高频调用；探针仅在 env 门控下启用。
private let mtFrameCallback: MTFrameCallbackC = { _, touches, numTouches, _, _ in
    callbackRouteLock.lock()
    let handler = activeTouchHandler
    callbackRouteLock.unlock()

    var contacts: [TouchSample] = []
    contacts.reserveCapacity(numTouches)
    let stride = MemoryLayout<MTTouchC>.stride
    for index in 0..<numTouches {
        let touch = touches.load(fromByteOffset: index * stride, as: MTTouchC.self)
        // 只收接触中的手指（making/touching）；离开信号由「帧缺席」表达，
        // 悬停（hover）与离开态不进帧。
        guard touch.state == MTTouchStateC.making || touch.state == MTTouchStateC.touching else { continue }

        // 坐标方向：MT 归一化 y 原点在左下（Kyome22 OMS Demo 渲染时
        // 以 1 - y 翻转），此处统一翻转为 0=上，消费端无需再处理。
        let x = Double(touch.normalizedVector.position.x)
        let y = 1.0 - Double(touch.normalizedVector.position.y)
        let major = Double(touch.majorAxis)
        let minor = Double(touch.minorAxis)

        if debugTouchSamples {
            debugSampleLock.lock()
            debugSampleCount += 1
            let count = debugSampleCount
            debugSampleLock.unlock()
            if count <= 400 {
                EventMonitor.debugLogForProbe("touch id=\(touch.fingerID) x=\(x) y=\(y) pressure=\(Double(touch.zTotal)) major=\(major) minor=\(minor) palm=\(TouchpointMonitor.isPalm(majorAxis: major, minorAxis: minor)) state=\(touch.state)")
            }
        }

        // 手掌误触防护：手掌接触椭圆显著大于手指（手指长轴 ~9–13mm），
        // 超过阈值即过滤，不进任何统计与显示。阈值经探针真机校准。
        if TouchpointMonitor.isPalm(majorAxis: major, minorAxis: minor) { continue }

        contacts.append(TouchSample(
            fingerID: touch.fingerID,
            x: x,
            y: y,
            pressure: Double(touch.zTotal),
            majorAxis: major,
            minorAxis: minor,
            angle: Double(touch.angle)
        ))
    }
    // 空帧也派发：消费端全量替换语义下，空帧 = 全部手指已离开。
    recordPressureSamples(contacts)
    handler?(TouchFrame(touches: contacts))
}

// MARK: - 触点监听器

/// 触控板触点监听器。以「帧」为单位派发全量触点（TouchFrame），
/// 坐标统一为 0–1（x 左→右，y 上→下），并已做手掌误触过滤。
/// 网格聚合 / 压力直方图 / 实时显示共用同一帧流。
public final class TouchpointMonitor: @unchecked Sendable {

    public typealias TouchHandler = @Sendable (_ frame: TouchFrame) -> Void

    /// 手掌过滤阈值（mm）：手指接触椭圆长轴 ~9–13mm，手掌显著更大。
    /// 经验值，随 INPUTSCAPE_DEBUG_TOUCH 探针数据校准。
    public static let palmMajorAxisThreshold: Double = 20.0
    public static let palmMinorAxisThreshold: Double = 15.0

    /// 手掌判定：接触椭圆任一轴达到手掌量级即视为误触。
    static func isPalm(majorAxis: Double, minorAxis: Double) -> Bool {
        majorAxis >= palmMajorAxisThreshold || minorAxis >= palmMinorAxisThreshold
    }

    public static let shared = TouchpointMonitor()

    private let lock = NSLock()
    private var devices: [MTDeviceRef] = []
    private var running = false

    public private(set) var isRunning: Bool = false

    private init() {}

    /// 框架与设备是否可用（设置页 / 引导预判用；不可用时功能自动空态）。
    public static func isDeviceAvailable() -> Bool {
        MTDeviceIsAvailable()
    }

    /// 启动监听全部触控板设备。handler 在 MT 内部线程调用，须快速返回。
    /// 已在运行时幂等返回 true（handler 固定，不重复注册）。
    @discardableResult
    public func start(handler: @escaping TouchHandler) -> Bool {
        // MTTouchC 布局守护：与 C 侧 96 字节布局不一致时宁可拒绝启动。
        guard MemoryLayout<MTTouchC>.stride == 96,
              MemoryLayout<MTTouchC>.size == 96 else { return false }
        lock.lock(); defer { lock.unlock() }
        if running { return true }
        guard MTDeviceIsAvailable() else { return false }
        // CF Create 规则的 +1 由 Swift ARC 自动接管，无需手动 CFRelease。
        guard let list = MTDeviceCreateList() else { return false }

        var created: [MTDeviceRef] = []
        let count = CFArrayGetCount(list)
        for index in 0..<count {
            guard let raw = CFArrayGetValueAtIndex(list, index) else { continue }
            guard let device = MTDeviceRef(bitPattern: UInt(bitPattern: raw)) else { continue }
            MTRegisterContactFrameCallback(device, mtFrameCallback)
            MTDeviceStart(device, 0)
            created.append(device)
        }
        guard !created.isEmpty else { return false }

        callbackRouteLock.lock()
        activeTouchHandler = handler
        callbackRouteLock.unlock()
        devices = created
        running = true
        isRunning = true
        return true
    }

    /// 近窗（默认 0.25 秒）内接触压力的最大值（无样本返回 nil）。
    /// 校准模式下点击重/轻判定用：点击瞬间手指仍在接触，取近窗最大
    /// zTotal 对照校准阈值。线程安全；仅内存，不落盘。
    public static func recentMaxContactPressure(within interval: TimeInterval = 0.25,
                                                at now: Date = Date()) -> Double? {
        pressureRingLock.lock(); defer { pressureRingLock.unlock() }
        pressureRing.removeAll { now.timeIntervalSince($0.at) > interval * 4 }
        var maxPressure: Double?
        for entry in pressureRing where now.timeIntervalSince(entry.at) <= interval {
            if maxPressure == nil || entry.pressure > maxPressure! {
                maxPressure = entry.pressure
            }
        }
        return maxPressure
    }

    /// 停止监听并释放设备（幂等）。
    public func stop() {
        lock.lock()
        guard running else { lock.unlock(); return }
        running = false
        isRunning = false
        let stopped = devices
        devices = []
        callbackRouteLock.lock()
        activeTouchHandler = nil
        callbackRouteLock.unlock()
        lock.unlock()
        for device in stopped {
            MTDeviceStop(device)
            MTDeviceRelease(device)
        }
        pressureRingLock.lock()
        pressureRing.removeAll()
        pressureRingLock.unlock()
    }
}
