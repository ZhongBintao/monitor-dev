import Foundation

// MARK: - 系统压力档跟踪（点击重/轻的权威判定依据）

/// 跟踪 NSEvent type 34（.pressure）的 stage 流（0 悬停 / 1 轻按 / 2 重按）。
/// 点击事件的左键按下到达时，取时间窗内的最大 stage 判定重/轻：
/// 系统在按压力度跨过重按门限时发 stage 2——这是 OS 层权威口径，
/// 无需任何阈值；没有压力档信号（鼠标、个别机型不投递）即为普通点击。
/// 纯逻辑、线程不安全，调用方（EventMonitor tap 回调）串行访问。
public struct PressureStageTracker: Sendable {

    /// 判定时间窗（秒）：重按的 stage 2 事件与随后左键按下几乎同时投递，
    /// 窗口只需覆盖两者间的投递间隔。待真机标定。
    public var window: TimeInterval

    private struct Entry: Sendable {
        let stage: Int
        let at: TimeInterval
    }
    private var entries: [Entry] = []
    private let capacity = 64

    public init(window: TimeInterval = 0.5) {
        self.window = window
    }

    /// 记录一次压力档事件（来自 tap 回调，串行）。
    public mutating func record(stage: Int, at t: TimeInterval) {
        entries.append(Entry(stage: stage, at: t))
        if entries.count > capacity {
            entries.removeFirst(entries.count - capacity)
        }
    }

    /// 时间窗内出现的最大 stage（无记录返回 nil → 普通点击）。
    public mutating func maxStage(within interval: TimeInterval? = nil, of t: TimeInterval) -> Int? {
        let horizon = interval ?? window
        entries.removeAll { t - $0.at > horizon * 4 }
        var maxStage: Int?
        for entry in entries where t - entry.at <= horizon {
            if maxStage == nil || entry.stage > maxStage! { maxStage = entry.stage }
        }
        return maxStage
    }

    public mutating func reset() {
        entries.removeAll()
    }
}

// MARK: - 按压校准（学习用户轻/重按的接触压力分界）

/// 校准会话：引导用户分别做轻按与重按，采集接触压力（MTTouch zTotal）样本，
/// 以**实时系统压力档自动标注**类别（stage < 2 轻 / ≥ 2 重），
/// 学出用户设备上的轻/重 zTotal 分界。
///
/// 校准假设（用户可在实时测试中验证）：轻按不触发触觉反馈，
/// 触发触觉咔哒（震动）的按压即为重按——系统 stage 2 即该门限，
/// 因此「实时看到的判定」与「触觉感受」应当一致。
///
/// MainActor：两条事件流（MT 触点帧 / CGEventTap 压力档）都经 AppModel
/// 转发到主线程后再进本会话，无需自行加锁。
@MainActor
public final class PressureCalibrationSession {

    public enum Phase: Equatable, Sendable {
        case idle
        case collectingLight
        case collectingHeavy
    }

    public struct Result: Equatable, Sendable {
        /// 学到的轻/重分界（两类中位数的均值）。
        public let threshold: Double
        public let lightMedian: Double
        public let heavyMedian: Double
        public let lightSamples: Int
        public let heavySamples: Int
        /// 类间分离度（重按中位数 − 轻按中位数）。
        public var separation: Double { heavyMedian - lightMedian }
        /// 成功条件：两类样本充足且分离度达到最小差（否则保留默认阈值）。
        public var isSuccess: Bool {
            separation >= Self.minimumSeparation
                && lightSamples >= Self.minimumSamples
                && heavySamples >= Self.minimumSamples
        }

        /// 最小类间差与最小类样本数（zTotal 噪声量级下取保守值，待标定）。
        public static let minimumSeparation: Double = 0.2
        public static let minimumSamples = 30
    }

    public private(set) var phase: Phase = .idle
    /// 实时压力档（最近一次 stage 事件），供 UI 与标注共用。
    public private(set) var currentStage: Int = 0
    /// 最近一次 stage 事件时刻：判断系统压力档信号是否存活
    /// （部分机型不投递 type 34 事件，此时标注回退到采集阶段）。
    private var lastStageAt: Date?
    private var lightSamples: [Double] = []
    private var heavySamples: [Double] = []
    /// 可注入时钟（测试用）。
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) {
        self.now = now
    }

    /// 系统压力档信号是否存活（1 秒内有过 stage 事件）。
    public var stageStreamAlive: Bool {
        guard let last = lastStageAt else { return false }
        return now().timeIntervalSince(last) < 1.0
    }

    public func beginLightCollection() {
        phase = .collectingLight
        currentStage = 0
        lightSamples = []
        heavySamples = []
    }

    public func beginHeavyCollection() {
        phase = .collectingHeavy
    }

    /// 压力档事件（EventMonitor 转发；同时是实时测试的判定来源）。
    public func recordStage(_ stage: Int) {
        currentStage = stage
        lastStageAt = now()
    }

    /// 接触压力样本（发布脉冲转发；标注优先级）：
    /// - 系统压力档信号存活 → 按实时 stage 标注（权威，防用户按错阶段）；
    /// - 无信号（机型不投递 type 34，currentStage 恒 0）→ 按当前采集
    ///   阶段标注（用户指令即标签）——否则所有样本都会被丢弃，
    ///   校准永远采不到数据（实测缺陷）。
    /// 悬停与无效值不采。
    public func recordContactPressure(_ pressure: Double) {
        guard phase == .collectingLight || phase == .collectingHeavy else { return }
        guard pressure > 0 else { return }
        if stageStreamAlive {
            if currentStage >= 2 {
                heavySamples.append(pressure)
            } else if currentStage == 1 {
                lightSamples.append(pressure)
            }
        } else {
            if phase == .collectingHeavy {
                heavySamples.append(pressure)
            } else {
                lightSamples.append(pressure)
            }
        }
    }

    public var lightSampleCount: Int { lightSamples.count }
    public var heavySampleCount: Int { heavySamples.count }

    /// 结束采集并计算结果（采样不足/分离不足时 isSuccess = false，
    /// 调用方保留默认阈值）。
    public func compute() -> Result {
        let light = Self.median(lightSamples)
        let heavy = Self.median(heavySamples)
        return Result(threshold: (light + heavy) / 2,
                      lightMedian: light,
                      heavyMedian: heavy,
                      lightSamples: lightSamples.count,
                      heavySamples: heavySamples.count)
    }

    public func reset() {
        phase = .idle
        currentStage = 0
        lastStageAt = nil
        lightSamples = []
        heavySamples = []
    }

    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count % 2 == 1 { return sorted[middle] }
        return (sorted[middle - 1] + sorted[middle]) / 2
    }
}

// MARK: - 校准结果持久化

/// 校准结果与双模式开关的持久化（UserDefaults；不含任何原始样本）。
public struct PressureCalibrationStore: Equatable, Sendable {

    static let thresholdKey = "Inputscape.PressureCalibratedThreshold"
    static let calibratedAtKey = "Inputscape.PressureCalibratedAt"
    static let useCalibrationKey = "Inputscape.PressureUseCalibration"

    /// 学到的轻/重分界（nil = 未校准）。
    public var threshold: Double?
    public var calibratedAt: Date?
    /// 是否启用校准判定（未校准时无意义，应用侧强制按 false 处理）。
    public var useCalibration: Bool

    public init(threshold: Double? = nil, calibratedAt: Date? = nil, useCalibration: Bool = false) {
        self.threshold = threshold
        self.calibratedAt = calibratedAt
        self.useCalibration = useCalibration
    }

    /// 是否处于可用状态（已校准且开关打开）。
    public var isActive: Bool { useCalibration && threshold != nil }

    public static func load(defaults: UserDefaults = .standard) -> PressureCalibrationStore {
        let threshold = defaults.object(forKey: Self.thresholdKey) as? Double
        let date = defaults.object(forKey: Self.calibratedAtKey) as? Date
        let use = defaults.bool(forKey: Self.useCalibrationKey)
        return PressureCalibrationStore(threshold: threshold, calibratedAt: date, useCalibration: use)
    }

    public func save(defaults: UserDefaults = .standard) {
        if let threshold {
            defaults.set(threshold, forKey: Self.thresholdKey)
        } else {
            defaults.removeObject(forKey: Self.thresholdKey)
        }
        if let calibratedAt {
            defaults.set(calibratedAt, forKey: Self.calibratedAtKey)
        } else {
            defaults.removeObject(forKey: Self.calibratedAtKey)
        }
        defaults.set(useCalibration, forKey: Self.useCalibrationKey)
    }

    /// 清除校准（恢复默认阈值与系统判定）。
    public mutating func clear() {
        self = PressureCalibrationStore()
    }
}
