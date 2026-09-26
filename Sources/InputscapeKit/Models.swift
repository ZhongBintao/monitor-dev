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
    case forceTouch     // 重按点击（系统压力档 stage 2 判定，或校准阈值判定）
    case zoom           // 历史口径：方向拆分前的缩放（含智能缩放），不再新增

    public var label: String {
        switch self {
        case .click: return "点击"
        case .scrollUp: return "上滚"
        case .scrollDown: return "下滚"
        case .smartZoom: return "智能缩放"
        case .swipe: return "滑动"
        case .forceTouch: return "重按点击"
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

// MARK: - 手指按压强度分档

/// 手指按压强度两档（MTTouch 手指压力连续值，按帧聚合）。
/// 分界经真机标定：< 1.0 轻按，≥ 1.0 重按（zTotal 电容总量实测可超 1，
/// 旧 0.25/0.55 三档无区分度，已废弃）。
/// Force Touch 深按判定（EventMonitor.forceTouchClickThreshold，点击瞬间口径）
/// 值域不同，独立标定、禁止联动。
public enum PressureTier: String, CaseIterable, Codable, Sendable {
    case light
    case heavy

    /// 默认轻 → 重分界：pressure ≥ 1.0 视为重按（可被用户校准阈值覆盖，
    /// 见 PressureCalibrationStore；点击的重/轻判定另有系统压力档权威口径，
    /// 与本阈值无关）。
    public static let heavyThreshold: Double = 1.0
    /// 压力直方图桶数：40 桶 × 0.05 步进，量程 0–2（>2 钳制末桶）。
    /// 旧 20 桶（量程 0–1）数据解码/合并时零填充迁移——桶 i 压力区间不变，无损。
    public static let histogramBuckets = 40
    /// 旧版直方图桶数（2026-09-24 之前落盘，量程 0–1）。
    public static let legacyHistogramBuckets = 20
    /// 单桶压力宽度（0.05；2.0 / 40）。
    public static let bucketWidth: Double = 0.05

    /// 压力 → 直方图桶序号（越界钳制；1.0 恰落桶 20 = 重按首桶）。
    /// 用 rounded 而非截断：0.05 非二进制精确值，截断会把 0.55 落错桶。
    public static func bucketIndex(_ pressure: Double) -> Int {
        min(histogramBuckets - 1, max(0, Int((pressure / bucketWidth).rounded())))
    }

    /// 桶序号 → 桶中心压力（直方图近似均值用）。
    public static func bucketCenter(_ index: Int) -> Double {
        (Double(index) + 0.5) * bucketWidth
    }

    public static func classify(_ pressure: Double) -> PressureTier {
        pressure >= heavyThreshold ? .heavy : .light
    }

    /// 按给定分界分档（校准阈值用；threshold ≤ 0 时全部按轻按兜底）。
    public static func classify(_ pressure: Double, threshold: Double) -> PressureTier {
        pressure >= max(threshold, 0) ? .heavy : .light
    }

    /// 直方图 → 两档汇总（默认分界 1.0，即桶 0–19 轻 / 20–39 重）。
    public static func tierCounts(in histogram: [Int]) -> (light: Int, heavy: Int) {
        tierCounts(in: histogram, threshold: heavyThreshold)
    }

    /// 直方图 → 两档汇总（按给定分界动态切桶：桶中心 < 分界为轻）。
    /// 校准阈值任意取值时切分线不再对齐桶边界，按桶中心判定。
    public static func tierCounts(in histogram: [Int], threshold: Double) -> (light: Int, heavy: Int) {
        var light = 0, heavy = 0
        for (index, count) in histogram.enumerated() {
            if bucketCenter(index) < max(threshold, 0) { light += count } else { heavy += count }
        }
        return (light, heavy)
    }

    /// 旧 20 桶直方图 → 40 桶：零填充（新旧桶 i 压力区间一致，无损）。
    public static func padLegacyHistogram(_ histogram: [Int]) -> [Int] {
        guard histogram.count == legacyHistogramBuckets else { return histogram }
        return histogram + Array(repeating: 0, count: histogramBuckets - legacyHistogramBuckets)
    }

    public var label: String {
        switch self {
        case .light: return "轻按"
        case .heavy: return "重按"
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
    /// 触控板触点热力图：24×16 网格按日触碰计数（行主序，row 0 = 顶行）。
    /// 触点位置仅按网格聚合，不保存轨迹、原始触点流或屏幕坐标。
    public var touchGrid: [Int]
    /// 手指按压强度直方图：40 桶 × 0.05 步进（量程 0–2），按 MTTouch 帧聚合。
    /// 帧累计即按压时长权重：按压越久、越重，对应桶计数越高。
    public var touchPressureHistogram: [Int]

    /// 热力图网格规格：24×16 = 384 格。
    public static let touchGridColumns = 24
    public static let touchGridRows = 16
    public static let touchGridCells = touchGridColumns * touchGridRows
    /// 旧 96×64 落盘规格（2026-09-24 当天的数据；解码/合并时 4×4 块求和降采样迁移）。
    public static let legacyTouchGridColumns = 96
    public static let legacyTouchGridRows = 64
    public static let legacyTouchGridCells = legacyTouchGridColumns * legacyTouchGridRows

    public init(date: String,
                keyCounts: [String: Int] = [:],
                trackpadCounts: [String: Int] = [:],
                comboCounts: [String: Int] = [:],
                buckets: [TimeBucket] = [],
                hourlyByOp: [String: [Int]] = [:],
                activeSeconds: Double = 0,
                touchGrid: [Int] = [],
                touchPressureHistogram: [Int] = []) {
        self.date = date
        self.keyCounts = keyCounts
        self.trackpadCounts = trackpadCounts
        self.comboCounts = comboCounts
        self.buckets = buckets
        self.hourlyByOp = hourlyByOp
        self.activeSeconds = activeSeconds
        self.touchGrid = touchGrid
        self.touchPressureHistogram = touchPressureHistogram
    }

    /// 自定义解码：touchGrid / touchPressureHistogram 为 2026-09 增量字段，
    /// 旧落盘 JSON 不含它们，用 decodeIfPresent 容缺；
    /// 旧 96×64 网格（6144 格）在解码时自动 4×4 块求和降采样为 384 格；
    /// 旧 20 桶压力直方图自动零填充为 40 桶。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        keyCounts = try container.decode([String: Int].self, forKey: .keyCounts)
        trackpadCounts = try container.decode([String: Int].self, forKey: .trackpadCounts)
        comboCounts = try container.decode([String: Int].self, forKey: .comboCounts)
        buckets = try container.decode([TimeBucket].self, forKey: .buckets)
        hourlyByOp = try container.decode([String: [Int]].self, forKey: .hourlyByOp)
        activeSeconds = try container.decode(Double.self, forKey: .activeSeconds)
        let decodedGrid = try container.decodeIfPresent([Int].self, forKey: .touchGrid) ?? []
        touchGrid = decodedGrid.count == DailyRecord.legacyTouchGridCells
            ? DailyRecord.downsampleLegacyTouchGrid(decodedGrid)
            : decodedGrid
        touchPressureHistogram = PressureTier.padLegacyHistogram(
            try container.decodeIfPresent([Int].self, forKey: .touchPressureHistogram) ?? [])
    }

    /// 旧 96×64 网格（6144 格）→ 24×16（384 格）：每 4×4 块求和，
    /// 一次性迁移路径（2026-09-24 当天按 96×64 落盘的数据，保留不丢）。
    public static func downsampleLegacyTouchGrid(_ grid: [Int]) -> [Int] {
        guard grid.count == legacyTouchGridCells else {
            return Array(repeating: 0, count: touchGridCells)
        }
        var out = Array(repeating: 0, count: touchGridCells)
        let factor = legacyTouchGridColumns / touchGridColumns // 4
        for row in 0..<touchGridRows {
            for column in 0..<touchGridColumns {
                var sum = 0
                for dr in 0..<factor {
                    for dc in 0..<factor {
                        sum += grid[(row * factor + dr) * legacyTouchGridColumns + (column * factor + dc)]
                    }
                }
                out[row * touchGridColumns + column] = sum
            }
        }
        return out
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

    /// 压力直方图样本总数（帧累计）。
    public var touchPressureSamples: Int {
        touchPressureHistogram.reduce(0, +)
    }

    /// 平均手指按压压力（直方图桶中心近似；无样本时为 nil）。
    public var touchPressureAverage: Double? {
        let samples = touchPressureSamples
        guard samples > 0 else { return nil }
        let weighted = touchPressureHistogram.enumerated()
            .reduce(0) { $0 + Double($1.element) * PressureTier.bucketCenter($1.offset) }
        return weighted / Double(samples)
    }

    /// 允许持久化的顶层字段（隐私不变量测试用）。
    public static let allowedEncodedKeys: Set<String> = [
        "date", "keyCounts", "trackpadCounts", "comboCounts", "buckets", "hourlyByOp", "activeSeconds",
        "touchGrid", "touchPressureHistogram"
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

    /// 实时触控板上的当前触点（归一化坐标 + 接触椭圆），仅内存。
    /// 触点集合以「帧全量替换」同步，与物理接触严格一致。
    public struct TouchDot: Sendable, Equatable, Identifiable {
        public let fingerID: Int32
        /// (handID, fingerID) 复合标识——帧内唯一、跨帧稳定，保证任意
        /// 手指数量的触点在显示层不撞键。
        public let touchID: Int32
        public let x: Double
        public let y: Double
        public let pressure: Double
        public let majorAxis: Double
        public let minorAxis: Double
        public let angle: Double
        public var id: Int32 { touchID }

        public init(fingerID: Int32, touchID: Int32, x: Double, y: Double, pressure: Double,
                    majorAxis: Double, minorAxis: Double, angle: Double) {
            self.fingerID = fingerID
            self.touchID = touchID
            self.x = x
            self.y = y
            self.pressure = pressure
            self.majorAxis = majorAxis
            self.minorAxis = minorAxis
            self.angle = angle
        }
    }

    public var lastKeyID: String?
    public var lastKeyDownAt: Date?
    public var recentTrackpad: [TrackpadEvent]
    /// 当前接触中的手指（实时触控板卡渲染源，30Hz 合并发布）。
    public var touchDots: [TouchDot]
    /// 观察启动时刻（计算空闲时长基准）。
    public var observationStartedAt: Date?

    public init() {
        self.recentTrackpad = []
        self.touchDots = []
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
    /// 触点热力图网格（多日合并，24×16 = 384 格）。
    public var touchGrid: [Int]
    /// 手指按压强度直方图（多日合并，40 桶 × 0.05，量程 0–2）。
    public var touchPressureHistogram: [Int]
    /// 轻/重分界阈值（系统默认 1.0，用户校准后为学习值）。
    /// 快照携带阈值，展示层据此动态切分轻/重，无需再查配置。
    public var pressureTierThreshold: Double

    public init(scope: PeriodScope, dayCount: Int, keyPresses: Int, trackpadOps: Int,
                activeSeconds: Double, keyCounts: [String: Int],
                comboCounts: [String: Int] = [:],
                trackpadCounts: [TrackpadOperationKind: Int],
                buckets: [TimeBucket], hourlyByOp: [TrackpadOperationKind: [Int]],
                daySeries: [DaySeriesPoint],
                touchGrid: [Int] = [],
                touchPressureHistogram: [Int] = [],
                pressureTierThreshold: Double = PressureTier.heavyThreshold) {
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
        self.touchGrid = touchGrid
        self.touchPressureHistogram = touchPressureHistogram
        self.pressureTierThreshold = pressureTierThreshold
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

    /// 压力直方图样本总数（帧累计，多日合并）。
    public var touchPressureSamples: Int {
        touchPressureHistogram.reduce(0, +)
    }

    /// 平均手指按压压力（直方图桶中心近似；无样本时为 nil）。
    public var touchPressureAverage: Double? {
        let samples = touchPressureSamples
        guard samples > 0 else { return nil }
        let weighted = touchPressureHistogram.enumerated()
            .reduce(0) { $0 + Double($1.element) * PressureTier.bucketCenter($1.offset) }
        return weighted / Double(samples)
    }

    /// 手指按压两档汇总（多日合并，按快照携带的阈值切分）。
    public var touchPressureTiers: (light: Int, heavy: Int) {
        PressureTier.tierCounts(in: touchPressureHistogram, threshold: pressureTierThreshold)
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
