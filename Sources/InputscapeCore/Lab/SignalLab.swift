import Foundation

// MARK: - Phase 0 信号实验室（REFACTOR_PLAN.md §8）
//
// 目的：任何信号先经「带标签的协议录制」验证，再进入统计与 UI。
// 监听层（EventMonitor / TouchpointMonitor）在 Lab 激活时把原始字段
// 喂给本单例；Lab 页面轮询快照显示实时读数，并按协议分阶段录制，
// 录制结果由纯函数评估（可单测），同时导出为 JSON fixture。
//
// 隐私：fixture 只含时间戳、手指数、压力/电容数值、键位 ID 与点击时刻，
// 不含触点坐标、字符或应用信息。

/// 一帧接触的聚合读数（Lab 只关心各字段的帧内最大值）。
public struct LabFrame: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var fingers: Int
    public var maxCapacitance: Double
    public var maxPressure: Double
    public var maxDensity: Double

    public init(t: TimeInterval, fingers: Int, maxCapacitance: Double, maxPressure: Double, maxDensity: Double) {
        self.t = t
        self.fingers = fingers
        self.maxCapacitance = maxCapacitance
        self.maxPressure = maxPressure
        self.maxDensity = maxDensity
    }
}

/// 单个手指的实时原始读数（Lab 读数表用）。
public struct LabContactReadout: Sendable, Equatable, Identifiable {
    public let touchID: Int32
    public let capacitance: Double
    public let pressure: Double
    public let pressureRawBits: Int32
    public let density: Double
    public let majorAxis: Double
    public let minorAxis: Double
    public var id: Int32 { touchID }

    public init(touchID: Int32, capacitance: Double, pressure: Double, pressureRawBits: Int32,
                density: Double, majorAxis: Double, minorAxis: Double) {
        self.touchID = touchID
        self.capacitance = capacitance
        self.pressure = pressure
        self.pressureRawBits = pressureRawBits
        self.density = density
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
    }
}

/// 按键 autorepeat 探针计数。
public struct LabKeyCounts: Sendable, Equatable, Codable {
    public var presses: Int = 0
    public var repeats: Int = 0
    public init(presses: Int = 0, repeats: Int = 0) {
        self.presses = presses
        self.repeats = repeats
    }
}

public struct LabKeyEvent: Codable, Sendable, Equatable {
    public var t: TimeInterval
    public var keyID: String
    public var isRepeat: Bool
}

public struct LabClick: Codable, Sendable, Equatable {
    public var t: TimeInterval
    /// 0 左键 / 1 右键 / 2 其他。
    public var button: Int
}

// MARK: - 协议

/// 一个验证协议：若干带指令的阶段，用户按指令操作，录制按阶段打标签。
public struct LabProtocol: Sendable, Identifiable, Equatable {
    public struct Step: Sendable, Equatable {
        public let id: String
        public let instruction: String
        /// 建议时长（秒）；UI 倒计时到 0 自动进入下一阶段。
        public let seconds: Int
    }

    public let id: String
    public let title: String
    public let summary: String
    public let steps: [Step]

    /// 按键 autorepeat：按住 Delete 约 2 秒再松开，共 5 次。
    /// 期望：Delete 非重复按下 = 5，重复事件 > 0。
    public static let keyRepeat = LabProtocol(
        id: "key-repeat",
        title: "按键重复",
        summary: "验证 autorepeat 标志能否把「按住」与「按下」分开。",
        steps: [
            Step(id: "hold", instruction: "按住 Delete 约 2 秒再松开，重复 5 次。", seconds: 20)
        ])

    /// MTTouch pressure 字段：静置 → 轻点 → 加压不按下 → 普通点击 → 重按。
    /// 期望：静置 < 轻点 < 点击 < 重按 逐档可分；对照 zTotal（电容）看谁区分度更高。
    /// 2026-10-26 首轮真机录制后修订：加入轻点阶段（轻点开启时也会产生点击事件，
    /// 必须单独测量）；重按改由压力本身分段计数（深按不产生新的点击事件）。
    public static let pressure = LabProtocol(
        id: "mt-pressure",
        title: "触控板压力字段",
        summary: "对比 MTTouch pressure 与 zTotal（电容）能否区分轻放、轻点、点击与重按。",
        steps: [
            Step(id: "rest", instruction: "一根手指轻放在触控板上，不移动、不按下。", seconds: 6),
            Step(id: "tap", instruction: "轻点 5 次：手指碰一下就抬起，不要按下去。", seconds: 8),
            Step(id: "push", instruction: "手指放着，逐渐加大力度，但不要按到咔哒。", seconds: 6),
            Step(id: "click", instruction: "正常按下点击 5 次（一次咔哒）。", seconds: 10),
            Step(id: "force", instruction: "用力重按 10 次：按到第二下更深的咔哒，每次之间完全松劲（手指可以不离开）。", seconds: 22)
        ])

    public static let all: [LabProtocol] = [.keyRepeat, .pressure]
}

/// 一次协议录制的全部原始数据（导出为 fixture）。
public struct LabRecording: Codable, Sendable, Equatable {
    public struct Phase: Codable, Sendable, Equatable {
        public var stepID: String
        public var start: TimeInterval
        public var end: TimeInterval
    }

    public var protocolID: String
    public var recordedAt: Date
    public var phases: [Phase]
    public var frames: [LabFrame]
    public var keys: [LabKeyEvent]
    public var clicks: [LabClick]

    public func phase(_ stepID: String) -> Phase? {
        phases.first { $0.stepID == stepID }
    }

    public func frames(in stepID: String) -> [LabFrame] {
        guard let p = phase(stepID) else { return [] }
        return frames.filter { $0.t >= p.start && $0.t < p.end }
    }

    public func clicks(in stepID: String) -> [LabClick] {
        guard let p = phase(stepID) else { return [] }
        return clicks.filter { $0.t >= p.start && $0.t < p.end }
    }
}

// MARK: - 评估（纯函数）

public enum LabEvaluation {

    public struct Verdict: Sendable, Equatable {
        public let passed: Bool
        public let lines: [String]
    }

    /// nearest-rank 分位数（空数组返回 0）。
    public static func percentile(_ p: Double, of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
        return sorted[min(sorted.count - 1, max(0, rank - 1))]
    }

    // MARK: 按键重复

    /// 通过条件：被按住最多的键（非重复按下）恰好 expectedPresses 次，
    /// 且出现了重复事件（证明标志有效、按住确实产生了重复）。
    public static func keyRepeat(_ rec: LabRecording, expectedPresses: Int = 5) -> Verdict {
        var perKey: [String: LabKeyCounts] = [:]
        for k in rec.keys {
            if k.isRepeat { perKey[k.keyID, default: .init()].repeats += 1 }
            else { perKey[k.keyID, default: .init()].presses += 1 }
        }
        guard let (key, counts) = perKey.max(by: { ($0.value.repeats, $0.value.presses) < ($1.value.repeats, $1.value.presses) }) else {
            return Verdict(passed: false, lines: ["没有收到任何按键事件。检查输入监听权限与观察状态。"])
        }
        let legacy = counts.presses + counts.repeats
        let passed = counts.presses == expectedPresses && counts.repeats > 0
        return Verdict(passed: passed, lines: [
            "\(key)：按下 \(counts.presses) 次（期望 \(expectedPresses)），重复事件 \(counts.repeats) 次。",
            "v1 口径会记为 \(legacy) 次按键。",
            passed ? "autorepeat 标志可靠：按住只算一次。"
                   : (counts.repeats == 0 ? "没有收到重复事件：按住时间可能太短，或标志未生效。"
                                          : "按下次数与期望不符：确认是否恰好按了 \(expectedPresses) 次。")
        ])
    }

    // MARK: 压力字段

    /// 一段时间区间（一次轻点 / 点击 / 重按的范围）。
    public struct Span: Sendable, Equatable {
        public let start: TimeInterval
        public let end: TimeInterval
    }

    /// 接触段：帧间隔超过 gap（手指抬起，MT 停发帧）即切段。用于轻点——
    /// 每次轻点都是一次「落下→抬起」，与是否产生点击事件（轻点开关）无关。
    public static func contactSpans(_ frames: [LabFrame], gap: TimeInterval = 0.05) -> [Span] {
        var spans: [Span] = []
        var start: TimeInterval?
        var last: TimeInterval = 0
        for f in frames {
            if let s = start, f.t - last > gap {
                spans.append(Span(start: s, end: last))
                start = f.t
            } else if start == nil {
                start = f.t
            }
            last = f.t
        }
        if let s = start { spans.append(Span(start: s, end: last)) }
        return spans
    }

    /// 压力段（迟滞）：pressure 升过 on 开段、降到 off 以下收段。用于重按——
    /// 深按不产生新的点击事件，手指也可能不离开，只能从压力本身切分。
    public static func pressureSpans(_ frames: [LabFrame], on: Double, off: Double) -> [Span] {
        var spans: [Span] = []
        var start: TimeInterval?
        var last: TimeInterval = 0
        for f in frames {
            if start == nil, f.maxPressure >= on {
                start = f.t
            } else if let s = start, f.maxPressure < off || f.t - last > 0.05 {
                spans.append(Span(start: s, end: last))
                start = f.maxPressure >= on ? f.t : nil
            }
            last = f.t
        }
        if let s = start { spans.append(Span(start: s, end: last)) }
        return spans
    }

    /// 点击窗：左键按下前 0.15s 到后 0.25s（压力峰值通常略早于按下事件）。
    public static func clickSpans(_ clicks: [LabClick]) -> [Span] {
        clicks.filter { $0.button == 0 }.map { Span(start: $0.t - 0.15, end: $0.t + 0.25) }
    }

    static func peaks(_ frames: [LabFrame], _ spans: [Span], _ value: (LabFrame) -> Double) -> [Double] {
        spans.compactMap { span in
            frames.filter { $0.t >= span.start && $0.t <= span.end }.map(value).max()
        }
    }

    /// 单个信号（pressure 或 capacitance）在各阶段的代表值。
    public struct SignalLevels: Sendable, Equatable {
        /// 静置阶段 P90（基线上沿）。
        public let rest: Double
        /// 轻点：每次接触段峰值的中位数。
        public let tap: Double
        /// 加压阶段最大值（仅参考，不参与判定）。
        public let push: Double
        /// 普通点击：每次点击窗内峰值的中位数。
        public let click: Double
        /// 重按：每个压力段峰值的中位数。
        public let force: Double
        /// 全程是否有变化（max - min > 0）。
        public let varies: Bool

        public var tapToClick: Double { ratio(click, tap) }
        public var clickToForce: Double { ratio(force, click) }

        private func ratio(_ a: Double, _ b: Double) -> Double {
            b > 0 ? a / b : (a > 0 ? .infinity : 0)
        }

        /// 轻点 vs 点击可分（「物理按下 vs 轻点」判定）。
        public func tapSeparable(minRatio: Double = 1.3) -> Bool {
            varies && rest < tap && tap < click && tapToClick >= minRatio
        }

        /// 点击 vs 重按可分（重按判定）。
        public func forceSeparable(minRatio: Double = 1.3) -> Bool {
            varies && click < force && clickToForce >= minRatio
        }

        public func isSeparable(minRatio: Double = 1.3) -> Bool {
            tapSeparable(minRatio: minRatio) && forceSeparable(minRatio: minRatio)
        }
    }

    /// 三类区间（所有信号共用同一组区间，比较才公平）。
    public struct PressureSpans: Sendable, Equatable {
        public let taps: [Span]
        public let clicks: [Span]
        public let forces: [Span]
    }

    /// 切分区间：轻点 = 接触段；点击 = 点击窗；重按 = 压力段，
    /// 开段门限取点击峰值中位数的 1.15 倍（重按必须明显超过普通点击），
    /// 收段门限取开段门限的一半。点击阶段没有数据时，重按段为空。
    public static func spans(_ rec: LabRecording) -> PressureSpans {
        let clicks = clickSpans(rec.clicks(in: "click"))
        let clickLevel = percentile(50, of: peaks(rec.frames(in: "click"), clicks) { $0.maxPressure })
        let forces = clickLevel > 0
            ? pressureSpans(rec.frames(in: "force"), on: clickLevel * 1.15, off: clickLevel * 0.575)
            : []
        return PressureSpans(taps: contactSpans(rec.frames(in: "tap")), clicks: clicks, forces: forces)
    }

    public static func levels(_ rec: LabRecording, _ spans: PressureSpans,
                              _ value: (LabFrame) -> Double) -> SignalLevels {
        let all = rec.frames.map(value)
        return SignalLevels(
            rest: percentile(90, of: rec.frames(in: "rest").map(value)),
            tap: percentile(50, of: peaks(rec.frames(in: "tap"), spans.taps, value)),
            push: rec.frames(in: "push").map(value).max() ?? 0,
            click: percentile(50, of: peaks(rec.frames(in: "click"), spans.clicks, value)),
            force: percentile(50, of: peaks(rec.frames(in: "force"), spans.forces, value)),
            varies: (all.max() ?? 0) - (all.min() ?? 0) > 0)
    }

    /// 两档之间的建议分界：几何平均（档位按倍数拉开，几何中点两侧余量相等）。
    public static func boundary(_ low: Double, _ high: Double) -> Double {
        (low * high).squareRoot()
    }

    public static func pressure(_ rec: LabRecording) -> (verdict: Verdict, pressure: SignalLevels, capacitance: SignalLevels) {
        let s = spans(rec)
        let p = levels(rec, s) { $0.maxPressure }
        let c = levels(rec, s) { $0.maxCapacitance }
        var lines: [String] = []
        if rec.frames.isEmpty {
            lines.append("没有收到触点帧。检查触控板监听是否在运行。")
            return (Verdict(passed: false, lines: lines), p, c)
        }
        lines.append("识别到轻点 \(s.taps.count) 次、点击 \(s.clicks.count) 次、重按 \(s.forces.count) 次（各期望 5）。")
        let enough = s.taps.count >= 3 && s.clicks.count >= 3 && s.forces.count >= 3
        if !p.varies {
            lines.append("pressure 全程不变：该字段在本机无数据，回退方案为仅统计「点击」。")
        } else {
            lines.append(p.tapSeparable()
                ? "轻点 vs 点击可分（\(String(format: "%.1f", p.tapToClick)) 倍），建议分界 \(String(format: "%.0f", boundary(p.tap, p.click)))。"
                : "轻点 vs 点击不够分开（需 ≥ 1.3 倍）。")
            lines.append(p.forceSeparable()
                ? "点击 vs 重按可分（\(String(format: "%.1f", p.clickToForce)) 倍），建议分界 \(String(format: "%.0f", boundary(p.click, p.force)))。"
                : "点击 vs 重按不够分开（需 ≥ 1.3 倍）。")
        }
        if !enough { lines.append("有一类次数少于 3，结论不可靠：按指令重录一次。") }
        lines.append(c.isSeparable() ? "zTotal（电容）也可分。" : "zTotal（电容）不可分——v1 按压统计的根因。")
        return (Verdict(passed: p.isSeparable() && enough, lines: lines), p, c)
    }
}

// MARK: - P1 时间戳单位探针

/// CGEvent.timestamp 原始值与系统 uptime 成对采样（首个与最近一个），
/// 用两者的增量之比推断时间戳单位：v1 一律按纳秒（/1e9）解读，
/// 但 Apple Silicon 上它可能是 mach tick（24 MHz）。
public struct LabTimestampProbe: Sendable, Equatable {
    public var firstRaw: UInt64
    public var firstUptime: TimeInterval
    public var lastRaw: UInt64
    public var lastUptime: TimeInterval
    public var samples: Int

    /// 每秒原始单位数；跨度不足 1 秒时不可信，返回 nil。
    public var unitsPerSecond: Double? {
        let dt = lastUptime - firstUptime
        guard samples >= 2, dt >= 1, lastRaw > firstRaw else { return nil }
        return Double(lastRaw - firstRaw) / dt
    }
}

extension LabEvaluation {

    public enum TimestampUnit: String, Sendable, Equatable {
        case nanoseconds, machTicks, unknown
    }

    /// 本机 mach tick 每秒数（mach_timebase_info：tick × numer / denom = ns）。
    public static var machTicksPerSecond: Double {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return 1e9 * Double(info.denom) / Double(info.numer)
    }

    /// 比率落在某个候选单位 ±5 % 内即判定为该单位。
    /// 两者相同（Intel 上 tick 即 ns）时优先报纳秒。
    public static func timestampUnit(unitsPerSecond: Double,
                                     machTicksPerSecond: Double = machTicksPerSecond) -> TimestampUnit {
        func near(_ target: Double) -> Bool { abs(unitsPerSecond / target - 1) <= 0.05 }
        if near(1e9) { return .nanoseconds }
        if near(machTicksPerSecond) { return .machTicks }
        return .unknown
    }
}

// MARK: - 实验室单例

/// Lab 页面轮询用的只读快照。
public struct LabSnapshot: Sendable {
    public var timestampProbe: LabTimestampProbe?
    public var keyTotals: LabKeyCounts
    public var lastKey: LabKeyEvent?
    public var contacts: [LabContactReadout]
    /// 最近 ~5 秒的接触帧（实时曲线）。
    public var recentFrames: [LabFrame]
    /// 接触期间的实测帧率（Hz），无接触时为 nil。
    public var frameRateHz: Double?
    public var recentClicks: [LabClick]
    public var isRecording: Bool
    public var now: TimeInterval
}

public final class SignalLab: @unchecked Sendable {

    public static let shared = SignalLab()

    private let lock = NSLock()
    private var active = false

    private var timestampProbe: LabTimestampProbe?
    private var keyTotals = LabKeyCounts()
    private var lastKey: LabKeyEvent?
    private var contacts: [LabContactReadout] = []
    private var ring: [LabFrame] = []
    private var clickRing: [LabClick] = []

    private var recording: LabRecording?
    private var currentPhase: (stepID: String, start: TimeInterval)?

    static let ringSeconds: TimeInterval = 5

    public init() {}

    /// Lab 页面可见时激活；未激活时所有 note* 只付一次加锁读布尔。
    public func setActive(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        active = on
        if !on {
            ring.removeAll()
            clickRing.removeAll()
            contacts.removeAll()
            timestampProbe = nil
            recording = nil
            currentPhase = nil
        }
    }

    public var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }

    // MARK: 输入（监听层调用，任意线程）

    /// P1：CGEvent.timestamp 原始值 + 回调时刻的 uptime。
    public func noteEventTimestamp(raw: UInt64, at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active, raw > 0 else { return }
        if var probe = timestampProbe {
            probe.lastRaw = raw
            probe.lastUptime = t
            probe.samples += 1
            timestampProbe = probe
        } else {
            timestampProbe = LabTimestampProbe(firstRaw: raw, firstUptime: t,
                                               lastRaw: raw, lastUptime: t, samples: 1)
        }
    }

    public func noteKeyDown(keyID: String, isRepeat: Bool, at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let event = LabKeyEvent(t: t, keyID: keyID, isRepeat: isRepeat)
        if isRepeat { keyTotals.repeats += 1 } else { keyTotals.presses += 1 }
        lastKey = event
        recording?.keys.append(event)
    }

    public func noteMouseDown(button: Int, at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        let click = LabClick(t: t, button: button)
        clickRing.append(click)
        clickRing.removeAll { t - $0.t > Self.ringSeconds }
        recording?.clicks.append(click)
    }

    public func noteTouchFrame(_ samples: [LabContactReadout], at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        contacts = samples
        guard !samples.isEmpty else { return }
        let frame = LabFrame(t: t, fingers: samples.count,
                             maxCapacitance: samples.map(\.capacitance).max() ?? 0,
                             maxPressure: samples.map(\.pressure).max() ?? 0,
                             maxDensity: samples.map(\.density).max() ?? 0)
        ring.append(frame)
        if let first = ring.first, t - first.t > Self.ringSeconds {
            ring.removeAll { t - $0.t > Self.ringSeconds }
        }
        recording?.frames.append(frame)
    }

    // MARK: 录制（Lab 页面调用）

    public func beginRecording(_ proto: LabProtocol, at t: TimeInterval) {
        lock.lock(); defer { lock.unlock() }
        guard active else { return }
        recording = LabRecording(protocolID: proto.id, recordedAt: Date(), phases: [],
                                 frames: [], keys: [], clicks: [])
        currentPhase = nil
    }

    /// 点 Lab 按钮（下一步 / 完成）结束阶段时，回溯剔除的窗口：按钮动作在
    /// 抬起时触发，其按下事件早于动作 ~0.1–0.3s。
    public static let uiClickWindow: TimeInterval = 0.6

    /// 进入某阶段（结束上一阶段）。byUIClick = 上一阶段由点按 Lab 按钮结束：
    /// 剔除该次点击，并把上一阶段截止到点击之前（按钮按压的压力峰也不计入）。
    public func enterPhase(_ stepID: String, at t: TimeInterval, byUIClick: Bool = false) {
        lock.lock(); defer { lock.unlock() }
        closePhaseLocked(at: t, byUIClick: byUIClick)
        currentPhase = (stepID, t)
    }

    /// 结束录制并返回结果（无录制返回 nil）。
    public func endRecording(at t: TimeInterval, byUIClick: Bool = false) -> LabRecording? {
        lock.lock(); defer { lock.unlock() }
        closePhaseLocked(at: t, byUIClick: byUIClick)
        let done = recording
        recording = nil
        return done
    }

    private func closePhaseLocked(at t: TimeInterval, byUIClick: Bool) {
        guard let p = currentPhase else { return }
        currentPhase = nil
        var end = t
        if byUIClick, var rec = recording {
            let isUIClick: (LabClick) -> Bool = { $0.t >= max(p.start, t - Self.uiClickWindow) && $0.t <= t }
            if let first = rec.clicks.filter(isUIClick).map(\.t).min() {
                end = max(p.start, first - 0.15)
            }
            rec.clicks.removeAll(where: isUIClick)
            recording = rec
        }
        recording?.phases.append(.init(stepID: p.stepID, start: p.start, end: end))
    }

    public func resetKeyTotals() {
        lock.lock(); defer { lock.unlock() }
        keyTotals = LabKeyCounts()
        lastKey = nil
    }

    // MARK: 快照

    public func snapshot(now t: TimeInterval = ProcessInfo.processInfo.systemUptime) -> LabSnapshot {
        lock.lock(); defer { lock.unlock() }
        let recent = ring.filter { t - $0.t <= Self.ringSeconds }
        // 帧率：最近 1 秒内的接触帧数 / 实际跨度（≥ 10 帧才可信）。
        let lastSecond = recent.filter { t - $0.t <= 1 }
        var rate: Double?
        if lastSecond.count >= 10, let a = lastSecond.first?.t, let b = lastSecond.last?.t, b > a {
            rate = Double(lastSecond.count - 1) / (b - a)
        }
        return LabSnapshot(timestampProbe: timestampProbe, keyTotals: keyTotals, lastKey: lastKey,
                           contacts: (t - (recent.last?.t ?? -.infinity) < 0.3) ? contacts : [],
                           recentFrames: recent, frameRateHz: rate,
                           recentClicks: clickRing.filter { t - $0.t <= Self.ringSeconds },
                           isRecording: recording != nil, now: t)
    }

    // MARK: fixture 导出

    /// 默认目录：~/Library/Application Support/Inputscape/lab
    public static func fixtureDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Inputscape/lab", isDirectory: true)
    }

    @discardableResult
    public static func saveFixture(_ rec: LabRecording, to directory: URL = fixtureDirectory()) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = directory.appendingPathComponent("\(rec.protocolID)-\(formatter.string(from: rec.recordedAt)).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(rec).write(to: url, options: .atomic)
        return url
    }
}
