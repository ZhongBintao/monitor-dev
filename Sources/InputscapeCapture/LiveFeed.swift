import Foundation
import InputscapeCore

/// 实时页的内存快照（不落盘）：当前按住的键、最新一帧触点、最近一次输入时刻。
/// 采集线程写入，实时页以 30 Hz 读取（只在实时页可见时）。
public final class LiveFeed: @unchecked Sendable {

    public struct Snapshot: Sendable {
        public var pressedKeys: Set<String>
        public var touches: [TouchPoint]
        public var lastInput: Date?
    }

    private let lock = NSLock()
    private var pressed: [String: Date] = [:]
    private var touches: [TouchPoint] = []
    private var touchesAt: Double = 0
    private var lastInput: Date?

    public init() {}

    func keyDown(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        pressed[id] = Date()
        lastInput = Date()
    }

    func keyUp(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        pressed[id] = nil
    }

    func noteInput() {
        lock.lock(); defer { lock.unlock() }
        lastInput = Date()
    }

    func setTouches(_ points: [TouchPoint], uptime: Double) {
        lock.lock(); defer { lock.unlock() }
        touches = points
        touchesAt = uptime
        if !points.isEmpty { lastInput = Date() }
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        pressed.removeAll()
        touches.removeAll()
    }

    public func snapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        // 漏掉松开事件的键（如切换窗口时）10 秒后自动熄灭；超过 0.3 秒没有新帧视为手指已离开
        let now = Date()
        pressed = pressed.filter { now.timeIntervalSince($0.value) < 10 }
        let fresh = ProcessInfo.processInfo.systemUptime - touchesAt < 0.3
        return Snapshot(pressedKeys: Set(pressed.keys), touches: fresh ? touches : [], lastInput: lastInput)
    }
}
