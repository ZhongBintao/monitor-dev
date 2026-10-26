import Foundation
import AppKit
import Observation
import InputscapeCore
import InputscapeStore

/// 采集主管：拥有事件 tap、触控板桥、输入源跟踪与分钟累加器，负责
/// 启停（权限 / 暂停 / 休眠 / 锁屏 / Lab）、每 15 秒写库、每分钟记录采集状态。
@MainActor
@Observable
public final class CaptureSupervisor {

    public enum Status: Equatable, Sendable {
        case starting, recording, paused, noPermission, asleep, locked

        public var label: String {
            switch self {
            case .starting: return "正在启动"
            case .recording: return "正在记录"
            case .paused: return "已暂停"
            case .noPermission: return "需要授权"
            case .asleep: return "休眠中"
            case .locked: return "已锁屏"
            }
        }
    }

    public static let flushInterval: TimeInterval = 15

    public private(set) var status: Status = .starting
    public private(set) var permission = Permissions.current()
    public private(set) var trackpadAvailable = false
    public private(set) var inputSource: InputSourceInfo = .unknown
    public private(set) var lastWriteError: String?
    public private(set) var labRecording = false

    public let database: InputscapeDatabase
    public let live = LiveFeed()

    @ObservationIgnored private let accumulator = MinuteAccumulator()
    @ObservationIgnored private let pressureRing = PressureRing()
    @ObservationIgnored private let touch: TouchPipeline
    @ObservationIgnored private let multitouch = MultitouchBridge()
    @ObservationIgnored private var tap: EventTap?
    @ObservationIgnored private var flushTimer: Timer?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "inputscape.store.write")
    @ObservationIgnored private var coverageCursor: Int
    @ObservationIgnored private var lastPointerMove: Date?
    @ObservationIgnored private var userPaused = false

    public init(database: InputscapeDatabase) {
        self.database = database
        self.touch = TouchPipeline(accumulator: accumulator, ring: pressureRing, live: live)
        self.coverageCursor = MinuteAccumulator.minute(of: Date())
    }

    // MARK: - 启停

    public func start() {
        observeSystem()
        refreshInputSource()
        permission = Permissions.current()
        guard permission.granted else {
            permission = Permissions.request()
            if !permission.granted {
                setStatus(.noPermission)
                pollPermission()
                return
            }
            return start()
        }
        permissionTimer?.invalidate()
        permissionTimer = nil
        startDevices()
        setStatus(userPaused ? .paused : .recording)
        if flushTimer == nil {
            let timer = Timer(timeInterval: Self.flushInterval, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.flush() }
            }
            RunLoop.main.add(timer, forMode: .common)
            flushTimer = timer
        }
    }

    /// 退出前调用：写入未落盘的增量。
    public func shutdown() {
        flush()
        writeQueue.sync {}
        tap?.stop()
        multitouch.stop()
    }

    public func requestPermission() {
        permission = Permissions.request()
        if permission.granted { start() }
    }

    public func setPaused(_ paused: Bool) {
        userPaused = paused
        guard status == .recording || status == .paused else { return }
        setStatus(paused ? .paused : .recording)
    }

    /// Lab 协议录制期间：事件只进 Lab，不进统计。
    public func setLabRecording(_ on: Bool) {
        labRecording = on
        updateAccumulatorEnabled()
        writeCoverageUpToNow()
    }

    private func startDevices() {
        if tap == nil {
            tap = EventTap { [weak self] event in
                // tap 回调本就在主 run loop
                MainActor.assumeIsolated { self?.handle(event) }
            }
        }
        if tap?.start() != true {
            setStatus(.noPermission)
            pollPermission()
            return
        }
        trackpadAvailable = multitouch.start(handler: touch.handler)
    }

    private func pollPermission() {
        guard permissionTimer == nil else { return }
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.permission = Permissions.current()
                if self.permission.granted { self.start() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        permissionTimer = timer
    }

    // MARK: - 事件

    private func handle(_ event: TapEvent) {
        let now = Date()
        switch event {
        case let .keyDown(id, isRepeat):
            live.keyDown(id)
            accumulator.recordKey(id: id, isRepeat: isRepeat, at: now)
        case let .keyUp(id):
            live.keyUp(id)
        case let .shortcut(combo):
            accumulator.recordShortcut(combo, at: now)
        case let .mouseDown(button, uptime):
            live.noteInput()
            touch.noteClick()
            guard button != 2 else {
                accumulator.recordClick(.other, at: now)
                return
            }
            // 物理按下 / 轻点 / 重按要看点击之后约 0.3 秒内的压力峰值，稍后判定
            DispatchQueue.main.asyncAfter(deadline: .now() + ClickClassifier.lookAhead + 0.05) { [weak self] in
                guard let self else { return }
                let peak = self.pressureRing.peak(from: uptime - ClickClassifier.lookBehind,
                                                  to: uptime + ClickClassifier.lookAhead)
                let kind = ClickClassifier.classify(isRightButton: button == 1, peakPressure: peak)
                self.accumulator.recordClick(kind, at: now)
            }
        case let .scroll(dx, dy, momentum):
            live.noteInput()
            accumulator.recordScroll(dx: dx, dy: dy, momentum: momentum, at: now)
        case .pointerMoved:
            // 指针移动只在触控板不可用时作为活动兜底（正常情况下由触点移动覆盖）
            guard !trackpadAvailable else { return }
            if let last = lastPointerMove {
                let dt = now.timeIntervalSince(last)
                if dt > 0 && dt < 1 { accumulator.recordPointer(seconds: dt, at: now) }
            }
            lastPointerMove = now
        }
    }

    // MARK: - 写库

    public func flush() {
        if let ended = touch.flushSession() {
            accumulator.recordSession(ended, at: Date())
        }
        let batch = accumulator.drain()
        let db = database
        writeQueue.async { [weak self] in
            do {
                try db.apply(batch)
            } catch {
                let message = error.localizedDescription
                Task { @MainActor in self?.lastWriteError = message }
            }
        }
        writeCoverageUpToNow()
    }

    private var coverageState: CoverageState {
        if labRecording && status == .recording { return .lab }
        switch status {
        case .recording, .starting: return trackpadAvailable ? .recording : .mtUnavailable
        case .paused: return .paused
        case .noPermission: return .noPermission
        case .asleep: return .asleep
        case .locked: return .locked
        }
    }

    /// 把 [cursor, 当前分钟] 记为当前状态。
    private func writeCoverageUpToNow() {
        let nowMinute = MinuteAccumulator.minute(of: Date())
        let from = coverageCursor
        let state = coverageState
        coverageCursor = nowMinute + 1
        let db = database
        writeQueue.async { try? db.writeCoverage(from: from, to: nowMinute + 1, state: state) }
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        // 先把截至现在的分钟按旧状态记下，再切换
        if status != .starting { writeCoverageUpToNow() }
        status = new
        updateAccumulatorEnabled()
        if new != .recording {
            accumulator.breakSegment()
            live.clear()
        }
    }

    private func updateAccumulatorEnabled() {
        accumulator.setEnabled(status == .recording && !labRecording)
    }

    // MARK: - 输入源

    public func refreshInputSource() {
        guard let info = InputSourceReader.current() else { return }
        inputSource = info
        accumulator.setInputSource(info)
    }

    // MARK: - 系统事件（休眠 / 唤醒 / 锁屏）

    private func observeSystem() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared.notificationCenter
        let distributed = DistributedNotificationCenter.default()

        func on(_ center: NotificationCenter, _ name: Notification.Name, _ action: @escaping @MainActor (CaptureSupervisor) -> Void) {
            let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    action(self)
                }
            }
            observers.append((center, token))
        }

        on(workspace, NSWorkspace.willSleepNotification) { s in s.goOffline(.asleep) }
        on(workspace, NSWorkspace.didWakeNotification) { s in s.comeBack(from: .asleep) }
        on(distributed, Notification.Name("com.apple.screenIsLocked")) { s in s.goOffline(.locked) }
        on(distributed, Notification.Name("com.apple.screenIsUnlocked")) { s in s.comeBack(from: .locked) }
        on(distributed, InputSourceReader.changedNotification) { s in s.refreshInputSource() }
        on(workspace, NSWorkspace.didActivateApplicationNotification) { s in s.refreshInputSource() }
    }

    private func goOffline(_ state: Status) {
        guard status == .recording || status == .paused else { return }
        flush()
        setStatus(state)
        multitouch.stop()
        touch.reset()
    }

    private func comeBack(from state: Status) {
        guard status == state else { return }
        // 休眠期间计时器不跑：先把离开的这段补记为休眠 / 锁屏
        writeCoverageUpToNow()
        refreshInputSource()
        tap?.stop()
        if tap?.start() != true {
            setStatus(.noPermission)
            pollPermission()
            return
        }
        trackpadAvailable = multitouch.restart(handler: touch.handler)
        setStatus(userPaused ? .paused : .recording)
    }
}

// MARK: - 触控板管线（MT 线程）

final class TouchPipeline: @unchecked Sendable {
    private let lock = NSLock()
    private let tracker = TouchTracker()
    private let accumulator: MinuteAccumulator
    private let ring: PressureRing
    private let live: LiveFeed
    private var lastMTTime = 0.0
    private var lastUptime = 0.0

    init(accumulator: MinuteAccumulator, ring: PressureRing, live: LiveFeed) {
        self.accumulator = accumulator
        self.ring = ring
        self.live = live
    }

    var handler: @Sendable (MultitouchFrame) -> Void {
        { [weak self] frame in self?.ingest(frame) }
    }

    private func ingest(_ frame: MultitouchFrame) {
        let maxPressure = frame.touches.map(\.pressure).max() ?? 0
        ring.record(t: frame.uptime, maxPressure: maxPressure, fingers: frame.touches.count)
        live.setTouches(frame.touches, uptime: frame.uptime)
        if !frame.labReadouts.isEmpty || frame.touches.isEmpty {
            SignalLab.shared.noteTouchFrame(frame.labReadouts, at: frame.uptime)
        }
        lock.lock()
        lastMTTime = frame.mtTime
        lastUptime = frame.uptime
        let out = tracker.ingest(time: frame.mtTime, touches: frame.touches)
        lock.unlock()
        let now = Date()
        if !out.contribution.isEmpty || out.contribution.moving {
            accumulator.recordTouch(out.contribution, at: now)
        }
        if let ended = out.endedSession {
            accumulator.recordSession(ended, at: now)
        }
    }

    func noteClick() {
        lock.lock(); defer { lock.unlock() }
        tracker.noteClick()
    }

    /// MT 无触点时不再发帧：用 uptime 推算当前 MT 时间来结束会话。
    func flushSession() -> TouchSessionKind? {
        lock.lock(); defer { lock.unlock() }
        guard lastUptime > 0 else { return nil }
        let nowMT = lastMTTime + (ProcessInfo.processInfo.systemUptime - lastUptime)
        return tracker.flush(now: nowMT)
    }

    func reset() {
        ring.clear()
        live.clear()
    }
}
