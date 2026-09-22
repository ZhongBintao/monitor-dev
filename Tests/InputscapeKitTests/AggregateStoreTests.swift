import XCTest
@testable import InputscapeKit

/// 本地 JSON 存储：读写回环、窗口查询与删除。
final class AggregateStoreTests: XCTestCase {

    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("InputscapeStoreTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        super.tearDown()
    }

    private func sampleRecord(date: String, keys: Int) -> DailyRecord {
        var record = DailyRecord(date: date)
        record.keyCounts["Space"] = keys
        record.keyCounts["A"] = 1
        record.trackpadCounts["click"] = 3
        record.trackpadCounts["scrollDown"] = 2
        record.buckets = [TimeBucket(index: 120, keyboard: keys, trackpad: 3)]
        record.hourlyByOp["click"] = Array(repeating: 0, count: 24)
        record.hourlyByOp["click"]?[10] = 3
        record.activeSeconds = 125.5
        return record
    }

    func testSaveLoadRoundtrip() throws {
        let store = JSONDayStore(directory: directory)
        let original = sampleRecord(date: "2026-09-22", keys: 42)
        try store.save(original)

        let loaded = store.load(day: "2026-09-22")
        XCTAssertEqual(loaded, original, "保存后读回应与原记录完全一致")
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("2026-09-22.json").path))
    }

    func testLoadRecentDaysWindow() throws {
        let store = JSONDayStore(directory: directory)
        for day in 1...10 {
            let date = String(format: "2026-08-%02d", day)
            try store.save(sampleRecord(date: date, keys: day))
        }
        let recent = store.loadRecentDays(7, before: "2026-08-11")
        XCTAssertEqual(recent.count, 7)
        XCTAssertEqual(recent.first?.date, "2026-08-04")
        XCTAssertEqual(recent.last?.date, "2026-08-10")
        XCTAssertEqual(recent.last?.keyCounts["Space"], 10)
    }

    func testLoadRecentDaysExcludesEndDay() throws {
        let store = JSONDayStore(directory: directory)
        try store.save(sampleRecord(date: "2026-09-21", keys: 1))
        try store.save(sampleRecord(date: "2026-09-22", keys: 2))
        let recent = store.loadRecentDays(7, before: "2026-09-22")
        XCTAssertEqual(recent.count, 1, "endDay（今天）由内存进行时数据承担，不应重复计入")
        XCTAssertEqual(recent.first?.date, "2026-09-21")
    }

    func testDeleteDayAndDeleteAll() throws {
        let store = JSONDayStore(directory: directory)
        try store.save(sampleRecord(date: "2026-09-21", keys: 1))
        try store.save(sampleRecord(date: "2026-09-22", keys: 2))

        try store.deleteDay("2026-09-21")
        XCTAssertNil(store.load(day: "2026-09-21"))
        XCTAssertEqual(store.listDays(), ["2026-09-22"])

        try store.deleteAll()
        XCTAssertTrue(store.listDays().isEmpty)
        XCTAssertNil(store.load(day: "2026-09-22"))
    }

    func testRejectsNonDayFilenames() throws {
        let store = JSONDayStore(directory: directory)
        try store.save(sampleRecord(date: "2026-09-22", keys: 1))
        // 注入一个非日期文件名，listDays/load 必须忽略。
        try Data("{}".utf8).write(to: directory.appendingPathComponent("not-a-day.json"))
        XCTAssertEqual(store.listDays(), ["2026-09-22"])
        XCTAssertNil(store.load(day: "../../etc/passwd"))
        XCTAssertNil(store.load(day: "not-a-day"))
    }
}
