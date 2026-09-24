import Foundation

// MARK: - 周期范围

/// 查询周期：今天 / 近 7 天 / 近 30 天。
public enum PeriodScope: String, CaseIterable, Sendable {
    case today
    case last7Days
    case last30Days

    public var dayCount: Int {
        switch self {
        case .today: return 1
        case .last7Days: return 7
        case .last30Days: return 30
        }
    }

    public var label: String {
        switch self {
        case .today: return "今天"
        case .last7Days: return "7 天"
        case .last30Days: return "30 天"
        }
    }
}

// MARK: - 触控板操作类别

/// 触控板操作类别（聚合口径，不含坐标与轨迹）。
/// 手势口径（2026-09-24 收缩）：只保留 Apple 官方事件直接计数——
/// 智能缩放（smartMagnify 事件）与三指轻扫（swipe 事件）；
/// 缩放分向 / 旋转 / 横滚 / 滚动会话等需要自定义识别逻辑的口径已删除。
/// `zoom` 保留为历史口径（仅方向拆分前的旧数据可见）。
public enum TrackpadOperationKind: String, CaseIterable, Codable, Sendable {
    case click          // 单击 / 双击等按压
    case scrollUp       // 上滚（手指方向语义）
    case scrollDown     // 下滚
    case smartZoom      // 智能缩放（双指双击，官方 smartMagnify 事件直计）
    case swipe          // 三指轻扫导航（官方 swipe 事件直计；双指轻扫在系统内表现为滚动）
    case forceTouch     // 深按（设备支持时）
    case zoom           // 历史口径：方向拆分前的缩放（含智能缩放），不再新增

    public var label: String {
        switch self {
        case .click: return "点击"
        case .scrollUp: return "上滚"
        case .scrollDown: return "下滚"
        case .smartZoom: return "智能缩放"
        case .swipe: return "滑动"
        case .forceTouch: return "Force Touch"
        case .zoom: return "缩放（历史）"
        }
    }

    /// 是否属于滚动类（构成里上下滚合并展示时用）。
    public var isScroll: Bool {
        switch self {
        case .scrollUp, .scrollDown:
            return true
        default:
            return false
        }
    }
}

// MARK: - 点击压力分档

/// 点击压力三档（Force Touch 触控板 leftMouseDown 的 kCGMouseEventPressure）。
/// 阈值为待真机标定的经验值（提案口径 0.4 / 0.9，可在真机验证后调整常量）；
/// 深按档阈值与 Force Touch 计数联动——pressure ≥ deepThreshold 即深按。
public enum PressureTier: String, CaseIterable, Codable, Sendable {
    case light
    case medium
    case deep

    /// 轻 → 中分界：pressure ≥ 0.4 视为中按。
    public static let mediumThreshold: Double = 0.4
    /// 中 → 深分界：pressure ≥ 0.9 视为深按（Force Touch 联动阈值）。
    public static let deepThreshold: Double = 0.9

    public static func classify(_ pressure: Double) -> PressureTier {
        if pressure >= deepThreshold { return .deep }
        if pressure >= mediumThreshold { return .medium }
        return .light
    }

    public var label: String {
        switch self {
        case .light: return "轻按"
        case .medium: return "中按"
        case .deep: return "深按"
        }
    }
}

// MARK: - 时间桶（5 分钟）

/// 每 5 分钟一个桶，一天 288 个，稀疏存储。
public struct TimeBucket: Codable, Sendable, Equatable {
    /// 当天桶序号 0..<288（分钟数 / 5）。
    public var index: Int
    public var keyboard: Int
    public var trackpad: Int

    public init(index: Int, keyboard: Int = 0, trackpad: Int = 0) {
        self.index = index
        self.keyboard = keyboard
        self.trackpad = trackpad
    }

    public static let perDay = 288

    /// 由时刻计算桶序号（按给定日历的本机时区）。
    public static func index(for date: Date, calendar: Calendar) -> Int {
        let minute = calendar.component(.minute, from: date)
        let hour = calendar.component(.hour, from: date)
        return (hour * 60 + minute) / 5
    }
}

// MARK: - 每日聚合记录（唯一落盘形态）

/// 本地持久化的唯一数据形态：只有键位 ID 计数、操作类别计数、
/// 5 分钟桶、分时段计数与活跃秒数。
/// 不含任何字符、按键序列、应用名称、屏幕坐标或原始事件。
/// 组合键（comboCounts）只保存「修饰键按住 + 普通键按下」的和弦快照
/// （如 "⌘C"），不保存时间序列，无法还原输入内容。
public struct DailyRecord: Codable, Sendable, Equatable {
    /// yyyy-MM-dd（本机时区）。
    public var date: String
    /// 物理键位 ID → 次数。
    public var keyCounts: [String: Int]
    /// 操作类别 rawValue → 次数。
    public var trackpadCounts: [String: Int]
    /// 组合键 ID（如 "⌘C"、"⇧⌘3"）→ 次数。
    public var comboCounts: [String: Int]
    public var buckets: [TimeBucket]
    /// 操作类别 rawValue → 24 小时分布。
    public var hourlyByOp: [String: [Int]]
    /// 活跃输入秒数（输入段模型：连续 60 秒无事件即结束当前段）。
    public var activeSeconds: Double
    /// 点击压力分档计数（PressureTier rawValue → 次数）。
    /// 点击的派生维度：不进 5 分钟桶、时段分布与活跃输入段。
    public var pressureTierCounts: [String: Int]
    /// 点击压力累计（pressure × 1000 的整数和），用于平均压力展示。
    public var pressureSumMilli: Int
    /// 触控板触点热力图：24×16 网格按日触碰计数（行主序，row 0 = 顶行）。
    /// 触点位置仅按网格聚合，不保存轨迹、原始触点流或屏幕坐标。
    public var touchGrid: [Int]

    /// 热力图网格规格（提案口径：24×16 = 384 格）。
    public static let touchGridColumns = 24
    public static let touchGridRows = 16
    public static let touchGridCells = touchGridColumns * touchGridRows

    public init(date: String,
                keyCounts: [String: Int] = [:],
                trackpadCounts: [String: Int] = [:],
                comboCounts: [String: Int] = [:],
                buckets: [TimeBucket] = [],
                hourlyByOp: [String: [Int]] = [:],
                activeSeconds: Double = 0,
                pressureTierCounts: [String: Int] = [:],
                pressureSumMilli: Int = 0,
                touchGrid: [Int] = []) {
        self.date = date
        self.keyCounts = keyCounts
        self.trackpadCounts = trackpadCounts
        self.comboCounts = comboCounts
        self.buckets = buckets
        self.hourlyByOp = hourlyByOp
        self.activeSeconds = activeSeconds
        self.pressureTierCounts = pressureTierCounts
        self.pressureSumMilli = pressureSumMilli
        self.touchGrid = touchGrid
    }

    /// 自定义解码：pressureTierCounts / pressureSumMilli / touchGrid 为
    /// 2026-09 增量字段，旧落盘 JSON 不含它们，用 decodeIfPresent 容缺。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        keyCounts = try container.decode([String: Int].self, forKey: .keyCounts)
        trackpadCounts = try container.decode([String: Int].self, forKey: .trackpadCounts)
        comboCounts = try container.decode([String: Int].self, forKey: .comboCounts)
        buckets = try container.decode([TimeBucket].self, forKey: .buckets)
        hourlyByOp = try container.decode([String: [Int]].self, forKey: .hourlyByOp)
        activeSeconds = try container.decode(Double.self, forKey: .activeSeconds)
        pressureTierCounts = try container.decodeIfPresent([String: Int].self,
                                                           forKey: .pressureTierCounts) ?? [:]
        pressureSumMilli = try container.decodeIfPresent(Int.self, forKey: .pressureSumMilli) ?? 0
        touchGrid = try container.decodeIfPresent([Int].self, forKey: .touchGrid) ?? []
    }

    public func trackpadCount(_ kind: TrackpadOperationKind) -> Int {
        trackpadCounts[kind.rawValue] ?? 0
    }

    public var trackpadTotal: Int {
        trackpadCounts.values.reduce(0, +)
    }

    public var keyTotal: Int {
        keyCounts.values.reduce(0, +)
    }

    /// 压力样本总数（三档之和）。
    public var pressureSampleTotal: Int {
        pressureTierCounts.values.reduce(0, +)
    }

    public func pressureCount(_ tier: PressureTier) -> Int {
        pressureTierCounts[tier.rawValue] ?? 0
    }

    /// 平均点击压力（无样本时为 nil）。
    public var pressureAverage: Double? {
        pressureSampleTotal > 0
            ? Double(pressureSumMilli) / Double(pressureSampleTotal) / 1000
            : nil
    }

    /// 允许持久化的顶层字段（隐私不变量测试用）。
    public static let allowedEncodedKeys: Set<String> = [
        "date", "keyCounts", "trackpadCounts", "comboCounts", "buckets", "hourlyByOp", "activeSeconds",
        "pressureTierCounts", "pressureSumMilli", "touchGrid"
    ]
}

// MARK: - 设备档案

public enum KeyboardTemplate: String, CaseIterable, Codable, Sendable {
    case macbookProUSANSI
    case macbookProISO
    case macbookProJIS
    case magicKeyboardANSI

    public var label: String {
        switch self {
        case .macbookProUSANSI: return "MacBook Pro 14/16″ US ANSI"
        case .macbookProISO: return "MacBook Pro ISO（后续支持）"
        case .macbookProJIS: return "MacBook Pro JIS（后续支持）"
        case .magicKeyboardANSI: return "Magic Keyboard（后续支持）"
        }
    }

    /// 首版仅内置 US ANSI 可选。
    public var isSelectable: Bool { self == .macbookProUSANSI }
}

public struct DeviceProfile: Codable, Sendable, Equatable {
    public var keyboardTemplate: KeyboardTemplate
    /// 用户在引导中确认了实际键盘模板。
    public var confirmed: Bool
    public var supportsForceTouch: Bool

    public init(keyboardTemplate: KeyboardTemplate = .macbookProUSANSI,
                confirmed: Bool = false,
                supportsForceTouch: Bool = true) {
        self.keyboardTemplate = keyboardTemplate
        self.confirmed = confirmed
        self.supportsForceTouch = supportsForceTouch
    }
}

// MARK: - 实时状态（仅内存，退出即丢弃）

/// 实时观察页数据。仅保存在内存中，不参与任何持久化。
public struct LiveState: Sendable, Equatable {
    public struct TrackpadEvent: Sendable, Equatable, Identifiable {
        public let id: UUID
        public let kind: TrackpadOperationKind
        public let at: Date
        public var isInProgress: Bool

        public init(id: UUID = UUID(), kind: TrackpadOperationKind, at: Date, isInProgress: Bool = false) {
            self.id = id
            self.kind = kind
            self.at = at
            self.isInProgress = isInProgress
        }
    }

    public var lastKeyID: String?
    public var lastKeyDownAt: Date?
    public var recentTrackpad: [TrackpadEvent]
    /// 观察启动时刻（计算空闲时长基准）。
    public var observationStartedAt: Date?

    public init() {
        self.recentTrackpad = []
    }

    public static let maxRecent = 8
}

// MARK: - 快照（视图消费的只读聚合）

public struct DaySeriesPoint: Sendable, Equatable, Identifiable {
    public var date: String
    public var keyboard: Int
    public var trackpad: Int
    public var activeSeconds: Double
    public var id: String { date }
}

/// 一次周期查询的完整聚合结果。
public struct AggregateSnapshot: Sendable, Equatable {
    public var scope: PeriodScope
    public var dayCount: Int
    public var keyPresses: Int
    public var trackpadOps: Int
    public var activeSeconds: Double
    /// 键位 ID → 次数（已合并多天）。
    public var keyCounts: [String: Int]
    /// 组合键 ID → 次数（已合并多天）。
    public var comboCounts: [String: Int]
    /// 操作类别 → 次数。
    public var trackpadCounts: [TrackpadOperationKind: Int]
    /// 合并后的 288 个 5 分钟桶。
    public var buckets: [TimeBucket]
    /// 操作类别 → 24 小时分布。
    public var hourlyByOp: [TrackpadOperationKind: [Int]]
    /// 按日序列（旧 → 新）。
    public var daySeries: [DaySeriesPoint]
    /// 点击压力分档 → 次数（多日合并）。
    public var pressureTierCounts: [PressureTier: Int]
    /// 点击压力累计（pressure × 1000 整数和，多日合并）。
    public var pressureSumMilli: Int
    /// 触点热力图网格（多日合并，384 格）。
    public var touchGrid: [Int]

    public init(scope: PeriodScope, dayCount: Int, keyPresses: Int, trackpadOps: Int,
                activeSeconds: Double, keyCounts: [String: Int],
                comboCounts: [String: Int] = [:],
                trackpadCounts: [TrackpadOperationKind: Int],
                buckets: [TimeBucket], hourlyByOp: [TrackpadOperationKind: [Int]],
                daySeries: [DaySeriesPoint],
                pressureTierCounts: [PressureTier: Int] = [:],
                pressureSumMilli: Int = 0,
                touchGrid: [Int] = []) {
        self.scope = scope
        self.dayCount = dayCount
        self.keyPresses = keyPresses
        self.trackpadOps = trackpadOps
        self.activeSeconds = activeSeconds
        self.keyCounts = keyCounts
        self.comboCounts = comboCounts
        self.trackpadCounts = trackpadCounts
        self.buckets = buckets
        self.hourlyByOp = hourlyByOp
        self.daySeries = daySeries
        self.pressureTierCounts = pressureTierCounts
        self.pressureSumMilli = pressureSumMilli
        self.touchGrid = touchGrid
    }

    public static func empty(_ scope: PeriodScope) -> AggregateSnapshot {
        AggregateSnapshot(scope: scope, dayCount: scope.dayCount, keyPresses: 0, trackpadOps: 0,
                          activeSeconds: 0, keyCounts: [:], comboCounts: [:], trackpadCounts: [:],
                          buckets: [], hourlyByOp: [:], daySeries: [])
    }

    /// 常用组合键 Top N。
    public func topCombos(_ n: Int) -> [(id: String, count: Int)] {
        comboCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(n).map { ($0.key, $0.value) }
    }

    public var hasData: Bool { keyPresses > 0 || trackpadOps > 0 }

    public func keyCount(_ id: String) -> Int { keyCounts[id] ?? 0 }

    /// 常用键位 Top N。
    public func topKeys(_ n: Int) -> [(id: String, count: Int)] {
        keyCounts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(n).map { ($0.key, $0.value) }
    }

    /// 触控板操作构成（含占比），按次数降序。
    public var trackpadRanking: [(kind: TrackpadOperationKind, count: Int, fraction: Double)] {
        let entries = TrackpadOperationKind.allCases
            .map { (kind: $0, count: trackpadCounts[$0] ?? 0) }
            .filter { $0.count > 0 }
            .sorted { $0.count > $1.count }
        let total = entries.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [] }
        return entries.map { ($0.kind, $0.count, Double($0.count) / Double(total)) }
    }

    /// 压力样本总数（多日合并）。
    public var pressureSamples: Int {
        pressureTierCounts.values.reduce(0, +)
    }

    public func pressureCount(_ tier: PressureTier) -> Int {
        pressureTierCounts[tier] ?? 0
    }

    /// 平均点击压力（多日合并；无样本时为 nil）。
    public var pressureAverage: Double? {
        pressureSamples > 0
            ? Double(pressureSumMilli) / Double(pressureSamples) / 1000
            : nil
    }

    /// 深按样本数（与 Force Touch 同一阈值联动，等于深按档计数）。
    public var pressureDeepCount: Int {
        pressureCount(.deep)
    }

    /// 热力图网格总触碰次数（多日合并）。
    public var touchTotal: Int {
        touchGrid.reduce(0, +)
    }

    /// 读取网格单元计数（越界返回 0）。
    public func touchCount(row: Int, column: Int) -> Int {
        guard row >= 0, row < DailyRecord.touchGridRows,
              column >= 0, column < DailyRecord.touchGridColumns else { return 0 }
        let index = row * DailyRecord.touchGridColumns + column
        guard index < touchGrid.count else { return 0 }
        return touchGrid[index]
    }

    /// 网格最热单元（计数与行列），用于"不只依赖颜色"的文字说明与无障碍摘要。
    public var touchPeak: (count: Int, row: Int, column: Int)? {
        var best: (count: Int, row: Int, column: Int)?
        for row in 0..<DailyRecord.touchGridRows {
            for column in 0..<DailyRecord.touchGridColumns {
                let count = touchCount(row: row, column: column)
                if count > 0, count > (best?.count ?? 0) {
                    best = (count, row, column)
                }
            }
        }
        return best
    }
}
