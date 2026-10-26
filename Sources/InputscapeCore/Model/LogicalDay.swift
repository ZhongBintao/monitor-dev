import Foundation

/// 逻辑日：本地时间 04:00 → 次日 04:00。熬夜到凌晨的工作算在开始的那个晚上。
/// 存储一律用 unix 分钟（unix 秒 / 60），逻辑日只在查询时换算。
public struct LogicalDay: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {

    public static let startHour = 4

    /// yyyy-MM-dd（本地日历）
    public let id: String

    public init?(id: String) {
        guard Self.parse(id) != nil else { return nil }
        self.id = id
    }

    /// 某个时刻所属的逻辑日。
    public init(containing date: Date, calendar: Calendar = .current) {
        let shifted = date.addingTimeInterval(-Double(Self.startHour) * 3600)
        self.id = Self.format(shifted, calendar: calendar)
    }

    public static func today(now: Date = Date()) -> LogicalDay { LogicalDay(containing: now) }

    public var description: String { id }

    public static func < (lhs: LogicalDay, rhs: LogicalDay) -> Bool { lhs.id < rhs.id }

    /// 起点（当天 04:00 本地时间）。
    public func start(calendar: Calendar = .current) -> Date {
        let midnight = Self.parse(id, calendar: calendar) ?? Date()
        return calendar.date(byAdding: .hour, value: Self.startHour, to: midnight) ?? midnight
    }

    /// 终点（次日 04:00，开区间）。
    public func end(calendar: Calendar = .current) -> Date {
        adding(days: 1).start(calendar: calendar)
    }

    public var minuteRange: Range<Int> {
        let s = Int(start().timeIntervalSince1970 / 60)
        let e = Int(end().timeIntervalSince1970 / 60)
        return s..<e
    }

    public func adding(days: Int, calendar: Calendar = .current) -> LogicalDay {
        let midnight = Self.parse(id, calendar: calendar) ?? Date()
        let moved = calendar.date(byAdding: .day, value: days, to: midnight) ?? midnight
        return LogicalDay(uncheckedID: Self.format(moved, calendar: calendar))
    }

    /// 星期（1 = 周日 … 7 = 周六，Calendar 约定）。
    public var weekday: Int {
        let midnight = Self.parse(id) ?? Date()
        return Calendar.current.component(.weekday, from: midnight)
    }

    public var date: Date { Self.parse(id) ?? Date() }

    public static func days(from: LogicalDay, through: LogicalDay) -> [LogicalDay] {
        guard from <= through else { return [] }
        var out: [LogicalDay] = []
        var d = from
        while d <= through && out.count < 4000 {
            out.append(d)
            d = d.adding(days: 1)
        }
        return out
    }

    // MARK: 内部

    private init(uncheckedID: String) { self.id = uncheckedID }

    private static func formatter(_ calendar: Calendar) -> DateFormatter {
        let f = DateFormatter()
        f.calendar = calendar
        f.timeZone = calendar.timeZone
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }

    private static func format(_ date: Date, calendar: Calendar) -> String {
        formatter(calendar).string(from: date)
    }

    private static func parse(_ id: String, calendar: Calendar = .current) -> Date? {
        formatter(calendar).date(from: id)
    }
}

/// 连续若干逻辑日（闭区间）。单日时 start == end。
public struct DayRange: Hashable, Sendable, Codable {
    public var start: LogicalDay
    public var end: LogicalDay

    public init(_ start: LogicalDay, _ end: LogicalDay) {
        self.start = min(start, end)
        self.end = max(start, end)
    }

    public static func single(_ day: LogicalDay) -> DayRange { DayRange(day, day) }

    public var isSingleDay: Bool { start == end }
    public var days: [LogicalDay] { LogicalDay.days(from: start, through: end) }
    public var dayCount: Int { days.count }

    public var minuteRange: Range<Int> { start.minuteRange.lowerBound..<end.minuteRange.upperBound }
    public var hourRange: Range<Int> { (minuteRange.lowerBound / 60)..<((minuteRange.upperBound + 59) / 60) }
}
