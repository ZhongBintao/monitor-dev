import Foundation

/// 采集层把匿名特征事件喂给累加器；累加器只在内存里按「分钟 × 输入源」累加增量，
/// 每 15 秒由采集主管 drain 一次交给存储层做增量 upsert。
/// 重启、跨午夜都不丢数据（已落盘的分钟不在内存里，增量直接叠加到库）。
///
/// 线程安全：事件 tap 在主线程、MultitouchSupport 在其内部线程调用，全部经锁。
public final class MinuteAccumulator: @unchecked Sendable {

    // MARK: 批次

    public struct RowKey: Hashable, Sendable {
        public let minute: Int
        public let source: String
    }

    public struct KeyHourKey: Hashable, Sendable {
        public let hour: Int
        public let source: String
        public let keyID: String
    }

    public struct ShortcutHourKey: Hashable, Sendable {
        public let hour: Int
        public let combo: String
    }

    public struct TouchHourKey: Hashable, Sendable {
        public let hour: Int
        public let cell: Int
    }

    public struct KeyTally: Equatable, Sendable {
        public var presses = 0
        public var repeats = 0
    }

    public struct TouchTally: Equatable, Sendable {
        public var landings = 0
        public var contactMs = 0.0
    }

    /// 一次 drain 出来的全部增量。
    public struct Batch: Sendable {
        public var rows: [RowKey: Counters] = [:]
        public var keys: [KeyHourKey: KeyTally] = [:]
        public var shortcuts: [ShortcutHourKey: Int] = [:]
        public var touch: [TouchHourKey: TouchTally] = [:]
        /// 本批次出现过的输入源（ID → 元数据），存储层据此维护 input_source 表。
        public var sources: [String: InputSourceInfo] = [:]

        public var isEmpty: Bool { rows.isEmpty && keys.isEmpty && shortcuts.isEmpty && touch.isEmpty }
    }

    // MARK: 状态

    /// 活动段间隔：相邻两次活动相隔 ≥ 60 秒即视为断开（孤立的一次活动记 0 秒）。
    public static let segmentGap: TimeInterval = 60

    private let lock = NSLock()
    private var batch = Batch()
    private var source: InputSourceInfo = .unknown
    private var lastActivity: Date?
    private var enabled = true

    public init() {}

    // MARK: 配置

    /// 暂停或 Lab 录制时关闭：事件直接丢弃，不进统计。
    public func setEnabled(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        enabled = on
        if !on { lastActivity = nil }
    }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return enabled
    }

    public func setInputSource(_ info: InputSourceInfo) {
        lock.lock(); defer { lock.unlock() }
        source = info
    }

    public var currentInputSource: InputSourceInfo {
        lock.lock(); defer { lock.unlock() }
        return source
    }

    /// 休眠 / 锁屏时调用：断开当前活动段，避免把离开的时间算进活跃时长。
    public func breakSegment() {
        lock.lock(); defer { lock.unlock() }
        lastActivity = nil
    }

    // MARK: 输入

    public func recordKey(id: String, isRepeat: Bool, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        let hour = Self.hour(of: date)
        var tally = batch.keys[KeyHourKey(hour: hour, source: source.id, keyID: id)] ?? KeyTally()
        if isRepeat {
            tally.repeats += 1
            addLocked(.keyRepeat, at: date)
        } else {
            tally.presses += 1
            addLocked(KeyClassifier.counter(for: id), at: date)
        }
        batch.keys[KeyHourKey(hour: hour, source: source.id, keyID: id)] = tally
        markActivityLocked(at: date)
    }

    public func recordShortcut(_ combo: String, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        batch.shortcuts[ShortcutHourKey(hour: Self.hour(of: date), combo: combo), default: 0] += 1
        addLocked(.shortcuts, at: date)
    }

    public func recordClick(_ kind: ClickKind, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        addLocked(kind.counter, at: date)
        if kind != .other { markActivityLocked(at: date) }
    }

    /// 滚动像素（取绝对值）；momentum = 松手后的惯性滚动，单独记一列。
    public func recordScroll(dx: Double, dy: Double, momentum: Bool, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        if momentum {
            addLocked(.scrollMomentumPx, abs(dx) + abs(dy), at: date)
        } else {
            addLocked(.scrollVerticalPx, abs(dy), at: date)
            addLocked(.scrollHorizontalPx, abs(dx), at: date)
            markActivityLocked(at: date)
        }
    }

    /// 一帧（或若干帧）触控板贡献。
    public func recordTouch(_ c: TouchContribution, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        let hour = Self.hour(of: date)
        addLocked(.touchSeconds, c.contactSeconds, at: date)
        addLocked(.touchMoveSeconds, c.moveSeconds, at: date)
        for cell in c.landings {
            batch.touch[TouchHourKey(hour: hour, cell: cell), default: TouchTally()].landings += 1
        }
        for (cell, ms) in c.contactMs where ms > 0 {
            batch.touch[TouchHourKey(hour: hour, cell: cell), default: TouchTally()].contactMs += ms
        }
        if c.moving { markActivityLocked(at: date) }
    }

    public func recordSession(_ kind: TouchSessionKind, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        addLocked(kind.counter, at: date)
    }

    /// 指针移动（仅触控板不可用时由采集层调用）。
    public func recordPointer(seconds: Double, at date: Date) {
        lock.lock(); defer { lock.unlock() }
        guard enabled else { return }
        addLocked(.pointerSeconds, seconds, at: date)
        markActivityLocked(at: date)
    }

    // MARK: 输出

    /// 取走全部增量（存储层负责叠加写入）。
    public func drain() -> Batch {
        lock.lock(); defer { lock.unlock() }
        let out = batch
        batch = Batch()
        return out
    }

    // MARK: 内部

    private func addLocked(_ counter: Counter, _ amount: Double = 1, at date: Date) {
        guard amount != 0 else { return }
        let key = RowKey(minute: Self.minute(of: date), source: source.id)
        batch.rows[key, default: Counters()].add(counter, amount)
        batch.sources[source.id] = source
    }

    /// 活动段：与上一次活动间隔 < 60 秒则把这段时间按分钟切分计入 active_s。
    private func markActivityLocked(at date: Date) {
        defer { lastActivity = max(lastActivity ?? date, date) }
        guard let last = lastActivity else { return }
        let gap = date.timeIntervalSince(last)
        guard gap > 0, gap < Self.segmentGap else { return }
        var cursor = last.timeIntervalSince1970
        let end = date.timeIntervalSince1970
        while cursor < end {
            let minute = Int(floor(cursor / 60))
            let boundary = Double(minute + 1) * 60
            let sliceEnd = min(boundary, end)
            let key = RowKey(minute: minute, source: source.id)
            batch.rows[key, default: Counters()].add(.activeSeconds, sliceEnd - cursor)
            batch.sources[source.id] = source
            cursor = sliceEnd
        }
    }

    public static func minute(of date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 60)) }
    public static func hour(of date: Date) -> Int { Int(floor(date.timeIntervalSince1970 / 3600)) }
}

/// 触控板对统计的贡献（由 TouchTracker 从原始帧算出，不含坐标序列）。
public struct TouchContribution: Equatable, Sendable {
    public var contactSeconds: Double = 0
    public var moveSeconds: Double = 0
    /// 新落下的手指所在网格（每根手指一次）
    public var landings: [Int] = []
    /// 各网格的手指接触毫秒数
    public var contactMs: [Int: Double] = [:]
    /// 本帧有手指在移动（计为活动）
    public var moving = false

    public init() {}

    public var isEmpty: Bool { contactSeconds == 0 && landings.isEmpty && contactMs.isEmpty }
}
