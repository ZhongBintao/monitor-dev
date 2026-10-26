import Foundation
import GRDB
import InputscapeCore

/// 本地 SQLite 数据库（REFACTOR_PLAN.md §4）。只存匿名聚合：没有文字、窗口标题、坐标或原始事件。
public final class InputscapeDatabase: @unchecked Sendable {

    public let writer: any DatabaseWriter

    public init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    /// ~/Library/Application Support/Inputscape/inputscape.sqlite
    public static func openDefault() throws -> InputscapeDatabase {
        let url = try defaultURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var config = Configuration()
        config.label = "Inputscape"
        let pool = try DatabasePool(path: url.path, configuration: config)
        return try InputscapeDatabase(writer: pool)
    }

    public static func inMemory() throws -> InputscapeDatabase {
        try InputscapeDatabase(writer: DatabaseQueue())
    }

    public static func supportDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        return base.appendingPathComponent("Inputscape", isDirectory: true)
    }

    public static func defaultURL() throws -> URL {
        try supportDirectory().appendingPathComponent("inputscape.sqlite")
    }

    // MARK: - 表结构

    static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()
        m.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE input_source (
                  id INTEGER PRIMARY KEY AUTOINCREMENT,
                  tis_id TEXT NOT NULL UNIQUE,
                  kind TEXT NOT NULL
                );
                """)
            let counterColumns = Counter.allCases
                .map { "\($0.rawValue) REAL NOT NULL DEFAULT 0" }
                .joined(separator: ",\n  ")
            try db.execute(sql: """
                CREATE TABLE minute_activity (
                  minute INTEGER NOT NULL,
                  src INTEGER NOT NULL,
                  \(counterColumns),
                  PRIMARY KEY (minute, src)
                ) WITHOUT ROWID;
                CREATE TABLE key_hourly (
                  hour INTEGER NOT NULL, src INTEGER NOT NULL, key_id TEXT NOT NULL,
                  presses INTEGER NOT NULL DEFAULT 0, repeats INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (hour, src, key_id)
                ) WITHOUT ROWID;
                CREATE TABLE shortcut_hourly (
                  hour INTEGER NOT NULL, combo TEXT NOT NULL, count INTEGER NOT NULL DEFAULT 0,
                  PRIMARY KEY (hour, combo)
                ) WITHOUT ROWID;
                CREATE TABLE touch_hourly (
                  hour INTEGER NOT NULL, cell INTEGER NOT NULL,
                  landings INTEGER NOT NULL DEFAULT 0, contact_ms REAL NOT NULL DEFAULT 0,
                  PRIMARY KEY (hour, cell)
                ) WITHOUT ROWID;
                CREATE TABLE coverage (
                  minute INTEGER PRIMARY KEY,
                  state TEXT NOT NULL
                );
                CREATE TABLE legacy_day (
                  date TEXT PRIMARY KEY,
                  keys INTEGER NOT NULL, clicks INTEGER NOT NULL,
                  scroll_legacy INTEGER NOT NULL, scroll_unit TEXT NOT NULL,
                  active_s REAL NOT NULL, flags TEXT NOT NULL
                );
                CREATE TABLE legacy_key (
                  date TEXT NOT NULL, key_id TEXT NOT NULL, count INTEGER NOT NULL,
                  PRIMARY KEY (date, key_id)
                ) WITHOUT ROWID;
                CREATE TABLE legacy_shortcut (
                  date TEXT NOT NULL, combo TEXT NOT NULL, count INTEGER NOT NULL,
                  PRIMARY KEY (date, combo)
                ) WITHOUT ROWID;
                CREATE TABLE legacy_touch (
                  date TEXT NOT NULL, cell INTEGER NOT NULL, contact_s REAL NOT NULL,
                  PRIMARY KEY (date, cell)
                ) WITHOUT ROWID;
                """)
        }
        return m
    }

    // MARK: - 写入

    /// 把累加器的增量叠加进库（ON CONFLICT … SET col = col + excluded.col）。
    public func apply(_ batch: MinuteAccumulator.Batch) throws {
        guard !batch.isEmpty else { return }
        try writer.write { db in
            var sourceIDs: [String: Int64] = [:]
            func sourceID(_ tisID: String) throws -> Int64 {
                if let id = sourceIDs[tisID] { return id }
                let kind = batch.sources[tisID]?.kind ?? (tisID.isEmpty ? .other : .other)
                try db.execute(sql: "INSERT OR IGNORE INTO input_source (tis_id, kind) VALUES (?, ?)",
                               arguments: [tisID, kind.rawValue])
                let id = try Int64.fetchOne(db, sql: "SELECT id FROM input_source WHERE tis_id = ?",
                                            arguments: [tisID]) ?? 0
                sourceIDs[tisID] = id
                return id
            }

            let columns = Counter.allCases.map(\.rawValue)
            let rowSQL = """
                INSERT INTO minute_activity (minute, src, \(columns.joined(separator: ", ")))
                VALUES (?, ?, \(columns.map { _ in "?" }.joined(separator: ", ")))
                ON CONFLICT (minute, src) DO UPDATE SET
                \(columns.map { "\($0) = \($0) + excluded.\($0)" }.joined(separator: ", "))
                """
            let rowStatement = try db.cachedStatement(sql: rowSQL)
            for (key, counters) in batch.rows {
                var args: [(any DatabaseValueConvertible)?] = [key.minute, try sourceID(key.source)]
                args += Counter.allCases.map { counters[$0] }
                try rowStatement.execute(arguments: StatementArguments(args))
            }

            let keyStatement = try db.cachedStatement(sql: """
                INSERT INTO key_hourly (hour, src, key_id, presses, repeats) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT (hour, src, key_id) DO UPDATE SET
                presses = presses + excluded.presses, repeats = repeats + excluded.repeats
                """)
            for (key, tally) in batch.keys {
                try keyStatement.execute(arguments: [key.hour, try sourceID(key.source), key.keyID,
                                                     tally.presses, tally.repeats])
            }

            let shortcutStatement = try db.cachedStatement(sql: """
                INSERT INTO shortcut_hourly (hour, combo, count) VALUES (?, ?, ?)
                ON CONFLICT (hour, combo) DO UPDATE SET count = count + excluded.count
                """)
            for (key, count) in batch.shortcuts {
                try shortcutStatement.execute(arguments: [key.hour, key.combo, count])
            }

            let touchStatement = try db.cachedStatement(sql: """
                INSERT INTO touch_hourly (hour, cell, landings, contact_ms) VALUES (?, ?, ?, ?)
                ON CONFLICT (hour, cell) DO UPDATE SET
                landings = landings + excluded.landings, contact_ms = contact_ms + excluded.contact_ms
                """)
            for (key, tally) in batch.touch {
                try touchStatement.execute(arguments: [key.hour, key.cell, tally.landings, tally.contactMs])
            }
        }
    }

    /// 写入采集状态（半开区间 [from, to)）。
    public func writeCoverage(from: Int, to: Int, state: CoverageState) throws {
        guard to > from else { return }
        try writer.write { db in
            let statement = try db.cachedStatement(sql: "INSERT OR REPLACE INTO coverage (minute, state) VALUES (?, ?)")
            for m in from..<min(to, from + 60 * 24 * 7) {
                try statement.execute(arguments: [m, state.rawValue])
            }
        }
    }

    /// 最近一条采集状态的分钟（启动时用来补「应用未运行」的边界）。
    public func lastCoverageMinute() throws -> Int? {
        try writer.read { db in try Int.fetchOne(db, sql: "SELECT MAX(minute) FROM coverage") }
    }

    // MARK: - 删除 / 导出

    public func delete(day: LogicalDay) throws {
        let minutes = day.minuteRange
        let hours = DayRange.single(day).hourRange
        try writer.write { db in
            try db.execute(sql: "DELETE FROM minute_activity WHERE minute >= ? AND minute < ?",
                           arguments: [minutes.lowerBound, minutes.upperBound])
            try db.execute(sql: "DELETE FROM coverage WHERE minute >= ? AND minute < ?",
                           arguments: [minutes.lowerBound, minutes.upperBound])
            for table in ["key_hourly", "shortcut_hourly", "touch_hourly"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE hour >= ? AND hour < ?",
                               arguments: [hours.lowerBound, hours.upperBound])
            }
            for table in ["legacy_day", "legacy_key", "legacy_shortcut", "legacy_touch"] {
                try db.execute(sql: "DELETE FROM \(table) WHERE date = ?", arguments: [day.id])
            }
        }
    }

    public func deleteAll() throws {
        try writer.write { db in
            for table in ["minute_activity", "key_hourly", "shortcut_hourly", "touch_hourly", "coverage",
                          "legacy_day", "legacy_key", "legacy_shortcut", "legacy_touch", "input_source"] {
                try db.execute(sql: "DELETE FROM \(table)")
            }
        }
    }

    /// 导出一份完整副本（VACUUM INTO）。
    public func export(to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try writer.writeWithoutTransaction { db in
            try db.execute(sql: "VACUUM INTO ?", arguments: [url.path])
        }
    }
}
