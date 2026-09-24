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

/// 触点状态机（MTTouchState）：只消费 3（making，指尖落下）与 4（touching，接触中）。
enum MTTouchStateC {
    static let making: UInt32 = 3
    static let touching: UInt32 = 4
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

/// C 回调入口：只做状态过滤 + 归一化坐标派发，MT 内部线程高频调用，
/// 必须保持纳秒级开销（无分配、无字符串、无日志）。
private let mtFrameCallback: MTFrameCallbackC = { _, touches, numTouches, _, _ in
    callbackRouteLock.lock()
    let handler = activeTouchHandler
    callbackRouteLock.unlock()
    guard let handler = activeTouchHandler, numTouches > 0 else { return }
    let stride = MemoryLayout<MTTouchC>.stride
    for index in 0..<numTouches {
        let touch = touches.load(fromByteOffset: index * stride, as: MTTouchC.self)
        guard touch.state == MTTouchStateC.making || touch.state == MTTouchStateC.touching else { continue }
        handler(Double(touch.normalizedVector.position.x), Double(touch.normalizedVector.position.y))
    }
}

// MARK: - 触点监听器

/// 触控板触点监听器（实验性）。聚合层只拿归一化坐标（0–1，x 左→右，y 上→下），
/// 网格聚合在 AggregationEngine 完成。
public final class TouchpointMonitor: @unchecked Sendable {

    public typealias TouchHandler = @Sendable (_ normalizedX: Double, _ normalizedY: Double) -> Void

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
    }
}
