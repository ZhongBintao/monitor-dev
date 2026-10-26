import Foundation
import GRDB
import InputscapeCore

/// 只读查询。全部是静态函数（接收 Database），便于放进 ValueObservation 自动刷新。
public enum Queries {

    // MARK: - 日报

    public static func report(_ db: Database, range: DayRange) throws -> DayReport {
        var report = DayReport(range: range)
        let minutes = range.minuteRange
        let hours = range.hourRange

        // 分钟计数（各输入源求和）
        let sums = Counter.allCases.map { "SUM(\($0.rawValue))" }.joined(separator: ", ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT minute, \(sums) FROM minute_activity
            WHERE minute >= ? AND minute < ? GROUP BY minute
            """, arguments: [minutes.lowerBound, minutes.upperBound])
        for row in rows {
            var c = Counters()
            for (i, counter) in Counter.allCases.enumerated() {
                c[counter] = row[i + 1] ?? 0
            }
            let minute: Int = row[0]
            report.minutes[minute] = c
            report.totals.merge(c)
        }

        // 采集状态
        let coverageRows = try Row.fetchAll(db, sql: "SELECT minute, state FROM coverage WHERE minute >= ? AND minute < ?",
                                            arguments: [minutes.lowerBound, minutes.upperBound])
        for row in coverageRows {
            if let state = CoverageState(rawValue: row["state"]) { report.coverage[row["minute"]] = state }
        }

        // 键位（按输入源类别）
        let keyRows = try Row.fetchAll(db, sql: """
            SELECT k.key_id, s.kind, SUM(k.presses) AS presses, SUM(k.repeats) AS repeats
            FROM key_hourly k JOIN input_source s ON s.id = k.src
            WHERE k.hour >= ? AND k.hour < ? GROUP BY k.key_id, s.kind
            """, arguments: [hours.lowerBound, hours.upperBound])
        for row in keyRows {
            let kind = InputSourceKind(rawValue: row["kind"]) ?? .other
            let keyID: String = row["key_id"]
            let presses: Int = row["presses"]
            let repeats: Int = row["repeats"]
            if presses > 0 { report.keysBySource[kind, default: [:]][keyID, default: 0] += presses }
            if repeats > 0 { report.repeatsByKey[keyID, default: 0] += repeats }
        }

        let shortcutRows = try Row.fetchAll(db, sql: """
            SELECT combo, SUM(count) AS n FROM shortcut_hourly WHERE hour >= ? AND hour < ? GROUP BY combo
            """, arguments: [hours.lowerBound, hours.upperBound])
        for row in shortcutRows { report.shortcuts[row["combo"]] = row["n"] }

        let touchRows = try Row.fetchAll(db, sql: """
            SELECT cell, SUM(landings) AS l, SUM(contact_ms) AS c FROM touch_hourly
            WHERE hour >= ? AND hour < ? GROUP BY cell
            """, arguments: [hours.lowerBound, hours.upperBound])
        for row in touchRows {
            let cell: Int = row["cell"]
            guard report.landings.indices.contains(cell) else { continue }
            report.landings[cell] = row["l"]
            report.contactMs[cell] = row["c"]
        }

        // 区间内没有 v2 数据的日子，用旧版数据补上
        let v2Days = Set(report.minutes.keys.map { LogicalDay(containing: Date(timeIntervalSince1970: Double($0) * 60)) })
        report.legacy = try legacyDays(db, range: range).filter { !v2Days.contains($0.day) }
        return report
    }

    // MARK: - 旧版日

    public static func legacyDays(_ db: Database, range: DayRange) throws -> [LegacyDay] {
        let dayRows = try Row.fetchAll(db, sql: "SELECT * FROM legacy_day WHERE date >= ? AND date <= ? ORDER BY date",
                                       arguments: [range.start.id, range.end.id])
        var out: [LegacyDay] = []
        for row in dayRows {
            let id: String = row["date"]
            guard let day = LogicalDay(id: id) else { continue }
            var keyCounts: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT key_id, count FROM legacy_key WHERE date = ?", arguments: [id]) {
                keyCounts[r["key_id"]] = r["count"]
            }
            var shortcuts: [String: Int] = [:]
            for r in try Row.fetchAll(db, sql: "SELECT combo, count FROM legacy_shortcut WHERE date = ?", arguments: [id]) {
                shortcuts[r["combo"]] = r["count"]
            }
            var grid = [Double](repeating: 0, count: TouchGrid.cellCount)
            for r in try Row.fetchAll(db, sql: "SELECT cell, contact_s FROM legacy_touch WHERE date = ?", arguments: [id]) {
                let cell: Int = r["cell"]
                if grid.indices.contains(cell) { grid[cell] = r["contact_s"] }
            }
            let flags = (row["flags"] as String).split(separator: ",").map(String.init)
            out.append(LegacyDay(day: day, keys: row["keys"], clicks: row["clicks"], activeSeconds: row["active_s"],
                                 flags: flags, keyCounts: keyCounts, shortcuts: shortcuts, contactSeconds: grid))
        }
        return out
    }

    // MARK: - 历史

    public struct HourStat: Equatable, Sendable {
        public var activeSeconds = 0.0
        public var keys = 0
        public var clicks = 0
    }

    /// unix 小时 → 统计（历史页的日汇总与「小时 × 星期」网格都基于此）。
    public static func hourly(_ db: Database, range: DayRange) throws -> [Int: HourStat] {
        let minutes = range.minuteRange
        let keyCols = Counter.keyPresses.map(\.rawValue).joined(separator: " + ")
        let clickCols = Counter.trackpadClicks.map(\.rawValue).joined(separator: " + ")
        let rows = try Row.fetchAll(db, sql: """
            SELECT minute / 60 AS hour, SUM(active_s) AS a, SUM(\(keyCols)) AS k, SUM(\(clickCols)) AS c
            FROM minute_activity WHERE minute >= ? AND minute < ? GROUP BY hour
            """, arguments: [minutes.lowerBound, minutes.upperBound])
        var out: [Int: HourStat] = [:]
        for row in rows {
            out[row["hour"]] = HourStat(activeSeconds: row["a"], keys: Int(row["k"] as Double), clicks: Int(row["c"] as Double))
        }
        return out
    }

    /// 每个逻辑日的摘要；没有 v2 数据的日子用旧版数据。
    public static func daySummaries(_ db: Database, range: DayRange) throws -> [DaySummary] {
        var byDay: [LogicalDay: DaySummary] = [:]
        for (hour, stat) in try hourly(db, range: range) {
            let day = LogicalDay(containing: Date(timeIntervalSince1970: Double(hour) * 3600))
            var s = byDay[day] ?? DaySummary(day: day, activeSeconds: 0, keys: 0, clicks: 0)
            s.activeSeconds += stat.activeSeconds
            s.keys += stat.keys
            s.clicks += stat.clicks
            byDay[day] = s
        }
        let hours = range.hourRange
        let kindRows = try Row.fetchAll(db, sql: """
            SELECT k.hour AS hour, s.kind AS kind, SUM(k.presses) AS n
            FROM key_hourly k JOIN input_source s ON s.id = k.src
            WHERE k.hour >= ? AND k.hour < ? GROUP BY k.hour, s.kind
            """, arguments: [hours.lowerBound, hours.upperBound])
        for row in kindRows {
            let hour: Int = row["hour"]
            let day = LogicalDay(containing: Date(timeIntervalSince1970: Double(hour) * 3600))
            guard var s = byDay[day] else { continue }
            let kind = InputSourceKind(rawValue: row["kind"]) ?? .other
            let n: Int = row["n"]
            if kind.isChinese { s.chineseKeys += n } else if kind == .latin { s.latinKeys += n }
            byDay[day] = s
        }
        for legacy in try legacyDays(db, range: range) where byDay[legacy.day] == nil {
            byDay[legacy.day] = DaySummary(day: legacy.day, activeSeconds: legacy.activeSeconds,
                                           keys: legacy.keys, clicks: legacy.clicks, isLegacy: true)
        }
        return byDay.values.filter { range.days.contains($0.day) }.sorted { $0.day < $1.day }
    }
}

// MARK: - 观察（UI 自动刷新）

extension InputscapeDatabase {

    public func report(range: DayRange) throws -> DayReport {
        try writer.read { db in try Queries.report(db, range: range) }
    }

    /// 数据变化时推送新报告（累加器每 15 秒写库一次）。
    public func observeReport(range: DayRange) -> AsyncValueObservation<DayReport> {
        ValueObservation
            .tracking { db in try Queries.report(db, range: range) }
            .removeDuplicates()
            .values(in: writer)
    }

    public struct HistoryData: Equatable, Sendable {
        public var days: [DaySummary] = []
        public var hourly: [Int: Queries.HourStat] = [:]
        public init() {}
    }

    public func observeHistory(range: DayRange) -> AsyncValueObservation<HistoryData> {
        ValueObservation
            .tracking { db -> HistoryData in
                var data = HistoryData()
                data.days = try Queries.daySummaries(db, range: range)
                data.hourly = try Queries.hourly(db, range: range)
                return data
            }
            .removeDuplicates()
            .values(in: writer)
    }
}
