import Foundation

/// 旧版（v1 JSON）导入的一天：只有日总量，没有分钟与输入源维度。
public struct LegacyDay: Equatable, Sendable {
    public var day: LogicalDay
    public var keys: Int
    public var clicks: Int
    public var activeSeconds: Double
    /// 例如 repeat_inflated（按住重复被算作按键）、active_time_broken
    public var flags: [String]
    public var keyCounts: [String: Int]
    public var shortcuts: [String: Int]
    /// 24×16 接触时长（秒，按 v1 帧数 / 125 近似）
    public var contactSeconds: [Double]

    public init(day: LogicalDay, keys: Int, clicks: Int, activeSeconds: Double, flags: [String],
                keyCounts: [String: Int], shortcuts: [String: Int], contactSeconds: [Double]) {
        self.day = day
        self.keys = keys
        self.clicks = clicks
        self.activeSeconds = activeSeconds
        self.flags = flags
        self.keyCounts = keyCounts
        self.shortcuts = shortcuts
        self.contactSeconds = contactSeconds
    }
}

/// 一个日期区间的完整报告（Today 页的数据源）。由存储层查询填充，纯数据。
public struct DayReport: Equatable, Sendable {
    public var range: DayRange
    /// 区间内全部 v2 计数之和
    public var totals = Counters()
    /// 分钟 → 计数（各输入源已求和）
    public var minutes: [Int: Counters] = [:]
    public var coverage: [Int: CoverageState] = [:]
    /// 输入源类别 → 键位 → 按下次数
    public var keysBySource: [InputSourceKind: [String: Int]] = [:]
    public var repeatsByKey: [String: Int] = [:]
    public var shortcuts: [String: Int] = [:]
    /// 24×16：落点次数 / 接触毫秒
    public var landings = [Double](repeating: 0, count: TouchGrid.cellCount)
    public var contactMs = [Double](repeating: 0, count: TouchGrid.cellCount)
    /// 区间内只有旧版数据的日子
    public var legacy: [LegacyDay] = []

    public init(range: DayRange) { self.range = range }

    public var hasData: Bool { !totals.isEmpty || !legacy.isEmpty }
    public var isLegacyOnly: Bool { totals.isEmpty && !legacy.isEmpty }

    /// 合并所有输入源（含旧版日）后的键位计数。
    public func keyCounts(filter: KeyFilter) -> [String: Int] {
        var out: [String: Int] = [:]
        for (kind, counts) in keysBySource where filter.includes(kind) {
            out.merge(counts, uniquingKeysWith: +)
        }
        if filter == .all {
            for day in legacy { out.merge(day.keyCounts, uniquingKeysWith: +) }
        }
        return out
    }

    public func shortcutCounts() -> [String: Int] {
        var out = shortcuts
        for day in legacy { out.merge(day.shortcuts, uniquingKeysWith: +) }
        return out
    }

    public var keyPresses: Int { totals.keyPresses + legacy.map(\.keys).reduce(0, +) }
    public var clicks: Int { totals.clicks + legacy.map(\.clicks).reduce(0, +) }
    public var activeSeconds: Double { totals[.activeSeconds] + legacy.map(\.activeSeconds).reduce(0, +) }

    public func keys(of kind: InputSourceKind) -> Int {
        keysBySource[kind]?.values.reduce(0, +) ?? 0
    }

    /// 中文输入法开启时的按键占比（只看 v2 有输入源的数据）。
    public var chineseShare: Double? {
        let zh = keys(of: .zhPinyin) + keys(of: .zhOther)
        let all = keysBySource.values.flatMap(\.values).reduce(0, +)
        return all > 0 ? Double(zh) / Double(all) : nil
    }

    /// 接触时长网格（秒），含旧版日。
    public var contactSecondsGrid: [Double] {
        var grid = contactMs.map { $0 / 1000 }
        for day in legacy where day.contactSeconds.count == grid.count {
            for i in grid.indices { grid[i] += day.contactSeconds[i] }
        }
        return grid
    }

    /// 每个逻辑日的节奏摘要。
    public func rhythm(for day: LogicalDay, now: Date = Date()) -> Rhythm.Summary {
        let range = day.minuteRange
        var active: [Int: Double] = [:]
        for (m, c) in minutes where range.contains(m) { active[m] = c[.activeSeconds] }
        let nowMinute = Int(now.timeIntervalSince1970 / 60)
        return Rhythm.summarize(range: range, activeSeconds: active,
                                coverage: coverage.filter { range.contains($0.key) },
                                now: range.contains(nowMinute) ? nowMinute : nil)
    }
}

/// 键盘热力图的输入源筛选。
public enum KeyFilter: String, CaseIterable, Sendable {
    case all, chinese, english

    public func includes(_ kind: InputSourceKind) -> Bool {
        switch self {
        case .all: return true
        case .chinese: return kind.isChinese
        case .english: return kind == .latin
        }
    }
}

/// 历史页：每个逻辑日的摘要。
public struct DaySummary: Equatable, Sendable, Identifiable {
    public var day: LogicalDay
    public var activeSeconds: Double
    public var keys: Int
    public var clicks: Int
    public var chineseKeys: Int
    public var latinKeys: Int
    public var isLegacy: Bool

    public var id: String { day.id }

    public init(day: LogicalDay, activeSeconds: Double, keys: Int, clicks: Int,
                chineseKeys: Int = 0, latinKeys: Int = 0, isLegacy: Bool = false) {
        self.day = day
        self.activeSeconds = activeSeconds
        self.keys = keys
        self.clicks = clicks
        self.chineseKeys = chineseKeys
        self.latinKeys = latinKeys
        self.isLegacy = isLegacy
    }

    public var chineseShare: Double? {
        let total = chineseKeys + latinKeys
        return total > 0 ? Double(chineseKeys) / Double(total) : nil
    }
}
