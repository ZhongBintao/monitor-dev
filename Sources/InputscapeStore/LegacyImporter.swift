import Foundation
import GRDB
import InputscapeCore

/// 导入 v1 的每日 JSON（REFACTOR_PLAN.md §8）。只读原文件，不移动、不修改；重复运行幂等。
public enum LegacyImporter {

    /// v1 文件位置：~/Library/Application Support/Inputscape/days/YYYY-MM-DD.json
    public static func defaultDirectory() throws -> URL {
        try InputscapeDatabase.supportDirectory().appendingPathComponent("days", isDirectory: true)
    }

    /// v1 统计口径：MultitouchSupport 约 125 Hz，一帧一根手指计 1 次。
    static let v1FrameRate = 125.0
    /// 从这天起 v1 的滚动按「会话」计数，之前按事件计数。
    static let scrollSessionsSince = "2026-09-25"

    struct V1Day: Decodable {
        var date: String
        var keyCounts: [String: Int]?
        var comboCounts: [String: Int]?
        var trackpadCounts: [String: Int]?
        var activeSeconds: Double?
        var touchGrid: [Double]?
    }

    @discardableResult
    public static func importAll(from directory: URL, into database: InputscapeDatabase) throws -> Int {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var imported = 0
        for url in files where url.pathExtension == "json" {
            guard let data = try? Data(contentsOf: url),
                  let day = try? JSONDecoder().decode(V1Day.self, from: data),
                  LogicalDay(id: day.date) != nil else { continue }
            if try importDay(day, into: database) { imported += 1 }
        }
        return imported
    }

    /// 已存在的日期跳过（返回 false）。
    static func importDay(_ v1: V1Day, into database: InputscapeDatabase) throws -> Bool {
        try database.writer.write { db in
            if try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM legacy_day WHERE date = ?)", arguments: [v1.date]) == true {
                return false
            }
            let keyCounts = v1.keyCounts ?? [:]
            let trackpad = v1.trackpadCounts ?? [:]
            let clicks = (trackpad["click"] ?? 0) + (trackpad["forceTouch"] ?? 0)
            let scroll = (trackpad["scrollUp"] ?? 0) + (trackpad["scrollDown"] ?? 0)
                + (trackpad["scrollHorizontal"] ?? 0)
            let unit = v1.date >= scrollSessionsSince ? "sessions" : "events"
            let flags = ["repeat_inflated", "active_time_unreliable"].joined(separator: ",")
            try db.execute(sql: """
                INSERT INTO legacy_day (date, keys, clicks, scroll_legacy, scroll_unit, active_s, flags)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [v1.date, keyCounts.values.reduce(0, +), clicks, scroll, unit,
                                 v1.activeSeconds ?? 0, flags])
            for (key, count) in keyCounts where count > 0 {
                try db.execute(sql: "INSERT OR REPLACE INTO legacy_key (date, key_id, count) VALUES (?, ?, ?)",
                               arguments: [v1.date, key, count])
            }
            for (combo, count) in v1.comboCounts ?? [:] where count > 0 && keepCombo(combo) {
                try db.execute(sql: "INSERT OR REPLACE INTO legacy_shortcut (date, combo, count) VALUES (?, ?, ?)",
                               arguments: [v1.date, combo, count])
            }
            for (cell, seconds) in contactSeconds(fromV1Grid: v1.touchGrid ?? []).enumerated() where seconds > 0 {
                try db.execute(sql: "INSERT OR REPLACE INTO legacy_touch (date, cell, contact_s) VALUES (?, ?, ?)",
                               arguments: [v1.date, cell, seconds])
            }
            return true
        }
    }

    /// v2 口径：只有按住 ⌘ 或 ⌃ 的才算快捷键（v1 把 ⇧ + 字母也算了）。
    static func keepCombo(_ combo: String) -> Bool {
        combo.contains("⌘") || combo.contains("⌃")
    }

    /// v1 网格（24×16 或早期的 96×64，单位：手指帧数）→ 24×16 接触秒数。
    static func contactSeconds(fromV1Grid grid: [Double]) -> [Double] {
        let cols = TouchGrid.columns, rows = TouchGrid.rows
        var out = [Double](repeating: 0, count: cols * rows)
        if grid.count == cols * rows {
            for i in grid.indices { out[i] = grid[i] / v1FrameRate }
        } else if grid.count == 96 * 64 {
            for y in 0..<64 {
                for x in 0..<96 {
                    out[(y / 4) * cols + (x / 4)] += grid[y * 96 + x] / v1FrameRate
                }
            }
        }
        return out
    }
}
