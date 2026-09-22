import XCTest
@testable import InputscapeKit

/// 聚合引擎：输入段（60 秒）、5 分钟桶、跨天与周期快照。
final class AggregationEngineTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!
    private var store: InMemoryTestStore!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar = cal
        now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 10, minute: 0, second: 0))
        store = InMemoryTestStore()
    }

    private var baseComponents: DateComponents {
        DateComponents(year: 2026, month: 9, day: 22, hour: 10, minute: 0, second: 0)
    }

    private func makeEngine() -> AggregationEngine {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let engine = AggregationEngine(calendar: cal, now: { [weak self] in self?.now ?? Date() })
        return engine
    }

    private func advance(_ seconds: TimeInterval) {
        now = now!.addingTimeInterval(seconds)
    }

    // MARK: - 基础计数

    func testKeyIngestIncrementsCountsAndBuckets() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "Space")      // 10:00 → 桶 120
        advance(120)                          // 10:02（同属桶 120：10:00–10:05）
        engine.ingestKey(keyID: "Space")
        engine.ingestKey(keyID: "A")

        let record = engine.todayRecord()
        XCTAssertEqual(record.keyCounts["Space"], 2)
        XCTAssertEqual(record.keyCounts["A"], 1)
        XCTAssertEqual(record.keyTotal, 3)
        XCTAssertEqual(record.buckets.first { $0.index == 120 }?.keyboard, 3,
                       "10:00 与 10:02 的三个事件都应落在桶 120")

        advance(300)                          // 10:07 → 桶 121
        engine.ingestKey(keyID: "B")
        let updated = engine.todayRecord()
        XCTAssertEqual(updated.buckets.first { $0.index == 121 }?.keyboard, 1,
                       "10:07 应落入下一个 5 分钟桶")

        // 10:00-10:05 → 桶 120（(10*60+0)/5）
        XCTAssertEqual(TimeBucket.index(for: calendar.date(from: baseComponents)!, calendar: calendar), 120)
        // 08:03 → (8*60+3)/5 = 96
        let t0803 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 8, minute: 3))!
        XCTAssertEqual(TimeBucket.index(for: t0803, calendar: calendar), 96)
        // 08:05 → 97
        let t0805 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 8, minute: 5))!
        XCTAssertEqual(TimeBucket.index(for: t0805, calendar: calendar), 97)
    }

    func testTrackpadOpsAndHourlyDistribution() {
        let engine = makeEngine()
        engine.ingestTrackpad(.click)
        engine.ingestTrackpad(.scrollUp)
        engine.ingestTrackpad(.scrollDown)
        engine.ingestTrackpad(.scrollDown)
        engine.ingestTrackpad(.zoom)
        engine.ingestTrackpad(.swipe)
        engine.ingestTrackpad(.forceTouch)

        let record = engine.todayRecord()
        XCTAssertEqual(record.trackpadCount(.click), 1)
        XCTAssertEqual(record.trackpadCount(.scrollUp), 1)
        XCTAssertEqual(record.trackpadCount(.scrollDown), 2)
        XCTAssertEqual(record.trackpadCount(.zoom), 1)
        XCTAssertEqual(record.trackpadCount(.swipe), 1)
        XCTAssertEqual(record.trackpadCount(.forceTouch), 1)
        XCTAssertEqual(record.trackpadTotal, 7)

        let hourSeries = record.hourlyByOp["click"]
        XCTAssertEqual(hourSeries?.count, 24)
        XCTAssertEqual(hourSeries?[10], 1, "10 点的点击应记入第 10 小时")
    }

    // MARK: - 输入段（活跃输入时长）

    /// 同段内事件（间隔 ≤ 60 秒）累计为一个输入段：段时长 = 段首到段尾。
    func testSessionExtendsWithin60Seconds() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "A")          // 10:00:00 段开始
        advance(30)
        engine.ingestKey(keyID: "B")          // 10:00:30
        XCTAssertEqual(engine.activeSecondsToday(), 30, accuracy: 0.001)
        advance(20)
        engine.ingestKey(keyID: "C")          // 10:00:50
        XCTAssertEqual(engine.activeSecondsToday(), 50, accuracy: 0.001)
    }

    /// 超过 60 秒无事件 → 结束当前段、开启新段。
    func testSessionEndsAfter60SecondGap() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "A")          // 10:00:00
        advance(30)
        engine.ingestKey(keyID: "B")          // 10:00:30，第一段 0→30 = 30s
        advance(90)                            // 10:02:00，间隔 90s > 60s
        engine.ingestKey(keyID: "C")          // 新段开始
        XCTAssertEqual(engine.activeSecondsToday(), 30, accuracy: 0.001, "第一段已结算为 30 秒")
        advance(10)
        engine.ingestKey(keyID: "D")          // 10:02:10，第二段 10s
        XCTAssertEqual(engine.activeSecondsToday(), 40, accuracy: 0.001)
    }

    func testCloseSessionSettlesOpenSegment() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "A")          // 10:00:00
        advance(45)
        engine.ingestKey(keyID: "B")          // 10:00:45
        engine.closeSession()
        advance(3600)
        XCTAssertEqual(engine.activeSecondsToday(), 45, accuracy: 0.001,
                       "closeSession 后段时长固定，不再延伸")
        // closeSession 后的新事件开启新段。
        engine.ingestKey(keyID: "C")
        XCTAssertEqual(engine.activeSecondsToday(), 45, accuracy: 0.001)
    }

    func testIsolatedEventCountsZeroActiveSeconds() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "A")
        engine.closeSession()
        XCTAssertEqual(engine.activeSecondsToday(), 0, accuracy: 0.001,
                       "孤立单次按键的段时长为 0")
    }

    // MARK: - 跨天

    func testRolloverAtMidnight() {
        let engine = makeEngine()
        engine.ingestKey(keyID: "A")
        advance(30)
        engine.ingestKey(keyID: "A")          // 当日 30s
        engine.closeSession()

        // 跳到 2026-09-23 08:00
        now = calendar.date(from: DateComponents(year: 2026, month: 9, day: 23, hour: 8))!
        engine.ingestKey(keyID: "B")

        let newRecord = engine.todayRecord()
        XCTAssertEqual(newRecord.date, "2026-09-23")
        XCTAssertEqual(newRecord.keyCounts["B"], 1)
        XCTAssertNil(newRecord.keyCounts["A"], "昨日计数不应带入新的一天")
        XCTAssertEqual(engine.activeSecondsToday(), 0, accuracy: 0.001, "新的一天从零开始")
    }

    // MARK: - 周期快照

    func testSnapshotMergesHistoricalDays() {
        // 预置 30 天历史。
        let formatter = { (offset: Int) -> String in
            let date = self.calendar.date(byAdding: .day, value: -offset, to: self.now!)!
            return AggregationEngine.dayString(for: date, calendar: self.calendar)
        }
        for offset in 1...30 {
            var record = DailyRecord(date: formatter(offset))
            record.keyCounts["Space"] = offset        // 第 offset 天按 offset 次
            record.trackpadCounts["click"] = 2
            record.activeSeconds = 60
            try? store.save(record)
        }

        let engine = makeEngine()
        engine.ingestKey(keyID: "Space")
        advance(10)
        engine.ingestTrackpad(.click)

        let today = engine.snapshot(scope: .today, store: store)
        XCTAssertEqual(today.keyPresses, 1)
        XCTAssertEqual(today.trackpadOps, 1)
        XCTAssertEqual(today.daySeries.count, 1)
        XCTAssertEqual(today.daySeries.first?.date, "2026-09-22")

        let week = engine.snapshot(scope: .last7Days, store: store)
        // 7 天窗口 = 今天 + 前 6 天：offset 1..6 → 1+2+...+6 = 21，加今天 1 = 22
        XCTAssertEqual(week.keyPresses, 22)
        XCTAssertEqual(week.trackpadOps, 6 * 2 + 1)
        XCTAssertEqual(week.daySeries.count, 7, "7 天快照应含 7 个逐日点（含今天）")

        let month = engine.snapshot(scope: .last30Days, store: store)
        XCTAssertEqual(month.keyPresses, 1 + 435) // 今天 + 前 29 天：29*30/2 = 435
        XCTAssertEqual(month.daySeries.count, 30)
    }

    func testComboCountingAndSnapshotMerge() {
        let engine = makeEngine()
        engine.ingestCombo("⌘C")
        engine.ingestCombo("⌘C")
        engine.ingestCombo("⇧⌘3")
        let record = engine.todayRecord()
        XCTAssertEqual(record.comboCounts["⌘C"], 2)
        XCTAssertEqual(record.comboCounts["⇧⌘3"], 1)
        XCTAssertEqual(record.activeSeconds, 0, accuracy: 0.001,
                       "组合是 keyDown 的派生维度，不影响输入段")

        // 落盘历史 + 今天合并。
        try? store.save(DailyRecord(date: "2026-09-21", keyCounts: ["A": 3], comboCounts: ["⌘C": 5]))
        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.comboCounts["⌘C"], 7)
        XCTAssertEqual(snap.comboCounts["⇧⌘3"], 1)
        XCTAssertEqual(snap.topCombos(1).first?.id, "⌘C")
        XCTAssertEqual(snap.topCombos(1).first?.count, 7)
    }

    /// 自定义起止区间：跨天、单日（起止同一天）、倒序交换、含/不含今天。
    func testSnapshotCustomRange() {
        for day in 1...5 {
            let date = String(format: "2026-09-%02d", day)
            try? store.save(DailyRecord(date: date, keyCounts: ["A": day]))
        }
        let engine = makeEngine()
        engine.ingestKey(keyID: "B") // 今天的进行时数据

        // 区间 09-02..09-04（不含今天）
        let snap = engine.snapshot(from: "2026-09-02", to: "2026-09-04", store: store)
        XCTAssertEqual(snap.keyPresses, 2 + 3 + 4)
        XCTAssertEqual(snap.daySeries.count, 3)
        XCTAssertNil(snap.keyCounts["B"], "区间不含今天时，今天的进行时数据不计入")

        // 单日区间（起止同一天）
        let single = engine.snapshot(from: "2026-09-03", to: "2026-09-03", store: store)
        XCTAssertEqual(single.keyPresses, 3)
        XCTAssertEqual(single.daySeries.count, 1)
        XCTAssertEqual(single.dayCount, 1)

        // 起止倒序自动交换
        let swapped = engine.snapshot(from: "2026-09-04", to: "2026-09-02", store: store)
        XCTAssertEqual(swapped.keyPresses, 2 + 3 + 4)

        // 含今天的区间：09-04、09-05、今天（中间零数据日不出现）
        let withToday = engine.snapshot(from: "2026-09-04", to: "2026-09-22", store: store)
        XCTAssertEqual(withToday.keyCounts["B"], 1)
        XCTAssertEqual(withToday.keyPresses, 4 + 5 + 1)
        XCTAssertEqual(withToday.daySeries.count, 3)

        // 日期枚举工具：单日与跨月
        XCTAssertEqual(AggregationEngine.dayRange("2026-09-22", "2026-09-22", calendar: calendar).count, 1)
        XCTAssertEqual(AggregationEngine.dayRange("2026-09-30", "2026-10-02", calendar: calendar),
                       ["2026-09-30", "2026-10-01", "2026-10-02"])
    }

    func testEmptySnapshotStates() {
        let engine = makeEngine()
        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertFalse(snap.hasData)
        XCTAssertEqual(snap.keyPresses, 0)
        XCTAssertEqual(snap.topKeys(5).count, 0)
        XCTAssertEqual(snap.trackpadRanking.count, 0)
        XCTAssertEqual(snap.daySeries.count, 0, "零数据日不进入逐日序列（保持趋势页空态语义）")
    }
}

/// 测试用内存存储。
final class InMemoryTestStore: AggregateStore, @unchecked Sendable {
    private let lock = NSLock()
    private var records: [String: DailyRecord] = [:]

    func save(_ record: DailyRecord) throws {
        lock.lock(); defer { lock.unlock() }
        records[record.date] = record
    }

    func load(day: String) -> DailyRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[day]
    }

    func loadRecentDays(_ count: Int, before endDay: String) -> [DailyRecord] {
        lock.lock(); defer { lock.unlock() }
        return records.keys.filter { $0 < endDay }.sorted().suffix(count).compactMap { records[$0] }
    }

    func deleteDay(_ day: String) throws {
        lock.lock(); defer { lock.unlock() }
        records.removeValue(forKey: day)
    }

    func deleteAll() throws {
        lock.lock(); defer { lock.unlock() }
        records.removeAll()
    }

    func listDays() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return records.keys.sorted()
    }
}
