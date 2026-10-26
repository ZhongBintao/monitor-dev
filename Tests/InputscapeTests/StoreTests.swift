import Testing
import Foundation
import GRDB
@testable import InputscapeCore
@testable import InputscapeStore

struct StoreTests {

    let day = LogicalDay(id: "2026-10-27")!
    var noon: Date { day.start().addingTimeInterval(8 * 3600) }  // 12:00

    let pinyin = InputSourceInfo(id: "com.apple.inputmethod.SCIM.ITABC", isKeyboardLayout: false, languages: ["zh-Hans"])
    let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", isKeyboardLayout: true, languages: ["en"])

    @Test func applyThenReport() throws {
        let db = try InputscapeDatabase.inMemory()
        let acc = MinuteAccumulator()
        acc.setInputSource(pinyin)
        for i in 0..<30 { acc.recordKey(id: "N", isRepeat: false, at: noon.addingTimeInterval(Double(i))) }
        acc.recordKey(id: "Space", isRepeat: false, at: noon.addingTimeInterval(31))
        acc.setInputSource(abc)
        acc.recordKey(id: "A", isRepeat: false, at: noon.addingTimeInterval(32))
        acc.recordShortcut("⌘C", at: noon)
        acc.recordClick(.tap, at: noon)
        var touch = TouchContribution()
        touch.landings = [5, 5, 7]
        touch.contactMs = [5: 120]
        touch.contactSeconds = 0.12
        acc.recordTouch(touch, at: noon)
        try db.apply(acc.drain())

        let report = try db.report(range: .single(day))
        #expect(report.keyPresses == 32)
        #expect(report.clicks == 1)
        #expect(report.keys(of: .zhPinyin) == 31)
        #expect(report.keys(of: .latin) == 1)
        #expect(report.keyCounts(filter: .chinese)["N"] == 30)
        #expect(report.keyCounts(filter: .english)["A"] == 1)
        #expect(report.shortcuts["⌘C"] == 1)
        #expect(report.landings[5] == 2)
        #expect(report.landings[7] == 1)
        #expect(report.contactMs[5] == 120)
        #expect(abs(report.activeSeconds - 32) < 0.001)
        #expect(abs((report.chineseShare ?? 0) - 31.0 / 32.0) < 1e-9)
    }

    @Test func incrementsAccumulateAcrossFlushes() throws {
        let db = try InputscapeDatabase.inMemory()
        let acc = MinuteAccumulator()
        acc.setInputSource(abc)
        acc.recordKey(id: "A", isRepeat: false, at: noon)
        try db.apply(acc.drain())
        acc.recordKey(id: "A", isRepeat: false, at: noon.addingTimeInterval(1))
        acc.recordKey(id: "A", isRepeat: true, at: noon.addingTimeInterval(2))
        try db.apply(acc.drain())
        let report = try db.report(range: .single(day))
        #expect(report.keyCounts(filter: .all)["A"] == 2)
        #expect(report.repeatsByKey["A"] == 1)
        #expect(report.minutes.count == 1)
    }

    @Test func coverageAndRhythm() throws {
        let db = try InputscapeDatabase.inMemory()
        let m = MinuteAccumulator.minute(of: noon)
        try db.writeCoverage(from: m, to: m + 30, state: .recording)
        try db.writeCoverage(from: m + 30, to: m + 40, state: .asleep)
        let acc = MinuteAccumulator()
        for s in stride(from: 0.0, to: 20 * 60, by: 5) { acc.recordKey(id: "A", isRepeat: false, at: noon.addingTimeInterval(s)) }
        try db.apply(acc.drain())
        let report = try db.report(range: .single(day))
        #expect(report.coverage[m] == .recording)
        #expect(report.coverage[m + 35] == .asleep)
        let rhythm = report.rhythm(for: day, now: noon.addingTimeInterval(3600))
        #expect(rhythm.stretches.count == 1)
        #expect(rhythm.longest?.length == 20)
        #expect(try db.lastCoverageMinute() == m + 39)
    }

    @Test func deleteDay() throws {
        let db = try InputscapeDatabase.inMemory()
        let acc = MinuteAccumulator()
        acc.recordKey(id: "A", isRepeat: false, at: noon)
        acc.recordKey(id: "B", isRepeat: false, at: noon.addingTimeInterval(86400))
        try db.apply(acc.drain())
        try db.delete(day: day)
        #expect(try db.report(range: .single(day)).hasData == false)
        #expect(try db.report(range: .single(day.adding(days: 1))).keyPresses == 1)
    }

    @Test func daySummariesAndHourly() throws {
        let db = try InputscapeDatabase.inMemory()
        let acc = MinuteAccumulator()
        acc.setInputSource(pinyin)
        for i in 0..<10 { acc.recordKey(id: "N", isRepeat: false, at: noon.addingTimeInterval(Double(i))) }
        acc.setInputSource(abc)
        for i in 0..<10 { acc.recordKey(id: "A", isRepeat: false, at: noon.addingTimeInterval(Double(86400 + i))) }
        try db.apply(acc.drain())
        let range = DayRange(day, day.adding(days: 1))
        let summaries = try db.writer.read { try Queries.daySummaries($0, range: range) }
        #expect(summaries.count == 2)
        #expect(summaries[0].chineseKeys == 10)
        #expect(summaries[1].latinKeys == 10)
        #expect(summaries[0].chineseShare == 1)
        let hourly = try db.writer.read { try Queries.hourly($0, range: range) }
        #expect(hourly.values.map(\.keys).reduce(0, +) == 20)
    }

    // MARK: 隐私

    /// 表里不应出现能存放文字、标题、网址或坐标的列。
    @Test func schemaHasNoContentColumns() throws {
        let db = try InputscapeDatabase.inMemory()
        let columns = try db.writer.read { db -> [String] in
            let tables = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'grdb_%' AND name NOT LIKE 'sqlite_%'")
            return try tables.flatMap { try db.columns(in: $0).map(\.name) }
        }
        let forbidden = ["text", "title", "url", "window", "app", "bundle", "char", "x", "y", "coord", "sequence"]
        for column in columns {
            let parts = column.lowercased().split(separator: "_").map(String.init)
            for word in forbidden {
                #expect(!parts.contains(word), "列 \(column) 看起来能存放内容")
            }
        }
    }

    // MARK: 旧版导入

    @Test func legacyImport() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var grid = [Double](repeating: 0, count: 384)
        grid[10] = 250
        let json: [String: Any] = [
            "date": "2026-09-30",
            "keyCounts": ["Space": 599, "Delete": 414, "I": 377],
            "comboCounts": ["⌘C": 12, "⇧I": 40, "⌃A": 2],
            "trackpadCounts": ["click": 1679, "forceTouch": 3, "scrollUp": 784, "scrollDown": 304],
            "activeSeconds": 9000,
            "touchGrid": grid,
        ]
        try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("2026-09-30.json"))
        let db = try InputscapeDatabase.inMemory()
        #expect(try LegacyImporter.importAll(from: dir, into: db) == 1)
        #expect(try LegacyImporter.importAll(from: dir, into: db) == 0)  // 幂等

        let legacyDay = LogicalDay(id: "2026-09-30")!
        let report = try db.report(range: .single(legacyDay))
        #expect(report.isLegacyOnly)
        #expect(report.keyPresses == 599 + 414 + 377)
        #expect(report.clicks == 1682)
        #expect(report.shortcutCounts()["⇧I"] == nil)
        #expect(report.shortcutCounts()["⌘C"] == 12)
        #expect(abs(report.contactSecondsGrid[10] - 2) < 1e-9)
        #expect(report.legacy.first?.flags.contains("repeat_inflated") == true)

        // 同一天有新版数据时以新版为准
        let acc = MinuteAccumulator()
        acc.recordKey(id: "A", isRepeat: false, at: legacyDay.start().addingTimeInterval(3600))
        try db.apply(acc.drain())
        let mixed = try db.report(range: .single(legacyDay))
        #expect(mixed.legacy.isEmpty)
        #expect(mixed.keyPresses == 1)
    }

    @Test func legacy96GridDownsamples() {
        var grid = [Double](repeating: 0, count: 96 * 64)
        grid[0] = 125; grid[1] = 125; grid[96] = 125
        let out = LegacyImporter.contactSeconds(fromV1Grid: grid)
        #expect(out.count == 384)
        #expect(out[0] == 3)
    }
}
