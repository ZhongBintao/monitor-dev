import Foundation
import CoreFoundation
import InputscapeCore

// MARK: - MultitouchSupport 私有框架绑定（最小接口面）
//
// 接口事实（函数原型、MTTouch 布局、状态取值）参考 calftrail/Touch、
// mhuusko5/M5MultitouchSupport、Kyome22/OpenMultitouchSupport（MIT）。
// 只向上层输出「接触中手指的归一化坐标 + 按压力度」，从不保存原始触点流。

public typealias MTDeviceRef = OpaquePointer

struct MTPointC { var x: Float; var y: Float }
struct MTVectorC { var position: MTPointC; var velocity: MTPointC }

/// MTTouch 内存布局（96 字节，全标量字段）。
struct MTTouchC {
    var frame: Int32
    var timestamp: Double
    var pathIndex: Int32
    var state: UInt32
    var fingerID: Int32
    var handID: Int32
    var normalizedVector: MTVectorC
    /// 电容总量（近似接触面积，不是力度；v1 误当压力用）
    var zTotal: Float
    /// 按压力度（Phase 0 验证为真实力度信号，整数值，疑似克）
    var pressure: Float
    var angle: Float
    var majorAxis: Float
    var minorAxis: Float
    var absoluteVector: MTVectorC
    var field14: Int32
    var field15: Int32
    var zDensity: Float
}

enum MTTouchStateC {
    static let making: UInt32 = 3
    static let touching: UInt32 = 4
}

typealias MTFrameCallbackC = @convention(c) (MTDeviceRef, UnsafeMutableRawPointer, Int, Double, Int) -> Void

@_silgen_name("MTDeviceIsAvailable") func MTDeviceIsAvailable() -> Bool
@_silgen_name("MTDeviceCreateList") func MTDeviceCreateList() -> CFArray?
@_silgen_name("MTDeviceIsBuiltIn") func MTDeviceIsBuiltIn(_ device: MTDeviceRef) -> Bool
@_silgen_name("MTDeviceStart") func MTDeviceStart(_ device: MTDeviceRef, _ options: Int32) -> Int32
@_silgen_name("MTDeviceStop") func MTDeviceStop(_ device: MTDeviceRef) -> Int32
@_silgen_name("MTRegisterContactFrameCallback")
func MTRegisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTFrameCallbackC)
@_silgen_name("MTUnregisterContactFrameCallback")
func MTUnregisterContactFrameCallback(_ device: MTDeviceRef, _ callback: MTFrameCallbackC)

/// 一帧：MT 时间戳（秒）+ 回调时刻的系统 uptime + 接触中的手指。
public struct MultitouchFrame: Sendable {
    public let mtTime: Double
    public let uptime: Double
    public let touches: [TouchPoint]
    /// Lab 用的原始字段读数（仅 Lab 激活时填充）
    public let labReadouts: [LabContactReadout]
}

// MARK: 回调路由（C 回调无上下文指针）

private let routeLock = NSLock()
private nonisolated(unsafe) var frameHandler: (@Sendable (MultitouchFrame) -> Void)?

/// 手掌过滤（mm）：手指接触椭圆长轴约 9–13 mm。
let palmMajorAxis = 20.0
let palmMinorAxis = 15.0

private let mtFrameCallback: MTFrameCallbackC = { _, touches, count, timestamp, _ in
    routeLock.lock()
    let handler = frameHandler
    routeLock.unlock()
    guard let handler else { return }

    let labActive = SignalLab.shared.isActive
    var points: [TouchPoint] = []
    var readouts: [LabContactReadout] = []
    points.reserveCapacity(count)
    let stride = MemoryLayout<MTTouchC>.stride
    for i in 0..<count {
        let t = touches.load(fromByteOffset: i * stride, as: MTTouchC.self)
        guard t.state == MTTouchStateC.making || t.state == MTTouchStateC.touching else { continue }
        let major = Double(t.majorAxis), minor = Double(t.minorAxis)
        if major >= palmMajorAxis || minor >= palmMinorAxis { continue }
        let id = (t.handID << 16) | (t.fingerID & 0xFFFF)
        points.append(TouchPoint(id: id,
                                 x: Double(t.normalizedVector.position.x),
                                 y: 1 - Double(t.normalizedVector.position.y),
                                 pressure: Double(t.pressure),
                                 majorAxis: major, minorAxis: minor, angle: Double(t.angle)))
        if labActive {
            readouts.append(LabContactReadout(touchID: id, capacitance: Double(t.zTotal),
                                              pressure: Double(t.pressure),
                                              pressureRawBits: Int32(bitPattern: t.pressure.bitPattern),
                                              density: Double(t.zDensity), majorAxis: major, minorAxis: minor))
        }
    }
    handler(MultitouchFrame(mtTime: timestamp, uptime: ProcessInfo.processInfo.systemUptime,
                            touches: points, labReadouts: readouts))
}

// MARK: - 桥

/// 只监听内置触控板。帧回调在 MT 内部线程，须快速返回。
public final class MultitouchBridge: @unchecked Sendable {

    private let lock = NSLock()
    private var devices: [MTDeviceRef] = []
    /// 设备列表持有设备引用（不对单个设备 release，避免 v1 的过度释放）
    private var deviceList: CFArray?

    public init() {}

    public var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return !devices.isEmpty
    }

    @discardableResult
    public func start(handler: @escaping @Sendable (MultitouchFrame) -> Void) -> Bool {
        guard MemoryLayout<MTTouchC>.stride == 96 else { return false }
        lock.lock(); defer { lock.unlock() }
        if !devices.isEmpty { return true }
        guard MTDeviceIsAvailable(), let list = MTDeviceCreateList() else { return false }
        routeLock.lock()
        frameHandler = handler
        routeLock.unlock()
        var started: [MTDeviceRef] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i),
                  let device = MTDeviceRef(bitPattern: UInt(bitPattern: raw)),
                  MTDeviceIsBuiltIn(device) else { continue }
            MTRegisterContactFrameCallback(device, mtFrameCallback)
            if MTDeviceStart(device, 0) == 0 {
                started.append(device)
            } else {
                MTUnregisterContactFrameCallback(device, mtFrameCallback)
            }
        }
        guard !started.isEmpty else { return false }
        devices = started
        deviceList = list
        return true
    }

    public func stop() {
        lock.lock()
        let stopping = devices
        devices = []
        lock.unlock()
        for device in stopping {
            MTUnregisterContactFrameCallback(device, mtFrameCallback)
            _ = MTDeviceStop(device)
        }
        lock.lock()
        deviceList = nil
        lock.unlock()
        routeLock.lock()
        frameHandler = nil
        routeLock.unlock()
    }

    /// 休眠唤醒后设备句柄可能失效：整体重建。
    @discardableResult
    public func restart(handler: @escaping @Sendable (MultitouchFrame) -> Void) -> Bool {
        stop()
        return start(handler: handler)
    }
}
