import XCTest
@testable import InputscapeKit

/// 隐私不变量（设计文档 §8 验收）：本地数据中不出现
/// 文字内容、按键序列、应用名称、鼠标屏幕坐标或原始事件。
final class PrivacyTests: XCTestCase {

    private func encode(_ record: DailyRecord) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record)
        let object = try JSONSerialization.jsonObject(with: data)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// 持久化形态的顶层字段必须严格等于白名单。
    func testPersistedSchemaOnlyContainsAllowedFields() throws {
        var record = DailyRecord(date: "2026-09-22")
        record.keyCounts["Space"] = 120
        record.keyCounts["A"] = 64
        record.trackpadCounts["click"] = 9
        record.trackpadCounts["scrollDown"] = 4
        record.buckets = [TimeBucket(index: 200, keyboard: 5, trackpad: 1)]
        record.hourlyByOp["click"] = Array(repeating: 0, count: 24)
        record.activeSeconds = 90

        let json = try encode(record)
        XCTAssertEqual(Set(json.keys), DailyRecord.allowedEncodedKeys,
                       "持久化字段必须与白名单一致：\(json.keys.sorted())")
    }

    /// 编码产物中不得出现禁用内容关键词。
    func testEncodedPayloadContainsNoForbiddenContent() throws {
        var record = DailyRecord(date: "2026-09-22")
        record.keyCounts["Space"] = 1
        record.trackpadCounts["click"] = 2

        let data = try JSONEncoder().encode(record)
        let payload = String(data: data, encoding: .utf8) ?? ""

        for forbidden in ["character", "text", "app", "bundle", "coordinate",
                          "location", "event", "sequence", "keystroke", "unicode"] {
            XCTAssertFalse(payload.lowercased().contains(forbidden),
                           "持久化产物不得包含 \(forbidden) 相关字段")
        }
    }

    /// 键位计数的键必须是主键盘图的物理键位 ID，而非字符。
    func testKeyCountsUsePhysicalKeyIDs() throws {
        var record = DailyRecord(date: "2026-09-22")
        for key in KeyboardLayoutSpec.observableKeys {
            record.keyCounts[key.id] = 1
        }
        let json = try encode(record)
        let keyCounts = try XCTUnwrap(json["keyCounts"] as? [String: Int])
        for id in keyCounts.keys {
            XCTAssertNotNil(KeyboardLayoutSpec.key(withID: id), "计数键 \(id) 不是物理键位 ID")
        }
        // "A" 是物理键位 ID（不是字符层内容）；但任意字符层内容不应出现在计数键里。
        XCTAssertNil(try? encode(record)["keySequence"])
    }

    /// 引擎产出的 DailyRecord 与落盘记录都不包含字符层信息。
    func testEngineOutputStaysAggregateOnly() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        var now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 9))!
        let engine = AggregationEngine(calendar: cal, now: { now })

        // 模拟一段真实输入（只传入键位 ID，模拟层根本拿不到字符）。
        for keyID in ["H", "E", "L", "L", "O", "Space", "W", "O", "R", "L", "D"] {
            engine.ingestKey(keyID: keyID)
            now = now.addingTimeInterval(0.2)
        }
        engine.ingestTrackpad(.click)

        let record = engine.todayRecord()
        let json = try encode(record)
        XCTAssertEqual(Set(json.keys), DailyRecord.allowedEncodedKeys)

        let keyCounts = try XCTUnwrap(json["keyCounts"] as? [String: Any])
        for key in keyCounts.keys {
            XCTAssertNotNil(KeyboardLayoutSpec.key(withID: key),
                            "引擎输出出现了非物理键位 ID 的键：\(key)")
        }
        // 逐字符序列不可能被复原：记录只包含计数。
        // "hello world" 共 11 次按键，L 出现 3 次。
        XCTAssertEqual(record.keyCounts["L"], 3)
        XCTAssertEqual(record.keyTotal, 11)
    }

    /// LiveState 必须不可编码（编译期即阻止其进入持久化路径）。
    func testLiveStateIsNotCodable() {
        let codable = Mirror(reflecting: LiveState.self)
        _ = codable
        XCTAssertFalse((LiveState.self as Any) is Codable.Type,
                       "LiveState 只允许保存在内存中，不得可编码")
    }
}
