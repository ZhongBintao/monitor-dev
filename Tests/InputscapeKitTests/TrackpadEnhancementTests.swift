import XCTest
@testable import InputscapeKit

/// 触控板增强（手势扩展 + 点击压力分档）：
/// 压力分档阈值、手势方向判定、引擎聚合、存储兼容
/// （旧 JSON 容缺 + 白名单同步）与快照合并。
final class TrackpadEnhancementTests: XCTestCase {

    private var calendar: Calendar!
    private var now: Date!
    private var store: InMemoryTestStore!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        calendar = cal
        now = cal.date(from: DateComponents(year: 2026, month: 9, day: 22, hour: 10))
        store = InMemoryTestStore()
    }

    private func makeEngine() -> AggregationEngine {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return AggregationEngine(calendar: cal, now: { [weak self] in self?.now ?? Date() })
    }

    // MARK: - 压力分档阈值

    func testPressureTierClassificationBoundaries() {
        XCTAssertEqual(PressureTier.classify(0.0), .light)
        XCTAssertEqual(PressureTier.classify(0.39), .light)
        XCTAssertEqual(PressureTier.classify(0.4), .medium, "0.4 进入中按档（下界含）")
        XCTAssertEqual(PressureTier.classify(0.89), .medium)
        XCTAssertEqual(PressureTier.classify(0.9), .deep, "0.9 进入深按档（下界含）")
        XCTAssertEqual(PressureTier.classify(1.5), .deep)
        XCTAssertEqual(PressureTier.classify(-0.2), .light, "异常负值按轻按兜底")
    }

    /// Force Touch 深按与深按档同一阈值联动（替换旧 1.5 未标定经验值）。
    func testForceTouchUsesDeepTierThreshold() {
        XCTAssertEqual(PressureTier.deepThreshold, 0.9)
        XCTAssertEqual(PressureTier.classify(0.9), .deep)
        XCTAssertEqual(PressureTier.classify(0.89), .medium, "深按阈值以下的点击不算 Force Touch")
    }

    // MARK: - 引擎聚合

    func testIngestPressureCountsTiersAndSum() {
        let engine = makeEngine()
        engine.ingestPressure(0.3)    // light
        engine.ingestPressure(0.5)    // medium
        engine.ingestPressure(0.95)   // deep

        let record = engine.todayRecord()
        XCTAssertEqual(record.pressureCount(.light), 1)
        XCTAssertEqual(record.pressureCount(.medium), 1)
        XCTAssertEqual(record.pressureCount(.deep), 1)
        XCTAssertEqual(record.pressureSumMilli, 300 + 500 + 950)
        XCTAssertEqual(record.pressureSampleTotal, 3)
        XCTAssertEqual(record.pressureAverage!, 1750.0 / 3 / 1000, accuracy: 1e-9)

        // 压力分档是点击的派生维度：不进 5 分钟桶、不影响活跃输入段。
        XCTAssertTrue(record.buckets.isEmpty, "压力样本不应进 5 分钟桶")
        XCTAssertEqual(engine.activeSecondsToday(), 0, accuracy: 0.001)
    }

    func testIngestPressureRespectsForceTouchGate() {
        let engine = makeEngine()
        engine.setForceTouchEnabled(false)
        engine.ingestPressure(0.95)
        XCTAssertEqual(engine.todayRecord().pressureSampleTotal, 0,
                       "关闭 Force Touch 开关后不应采集压力分档")
        XCTAssertFalse(engine.isForceTouchEnabled())
        engine.setForceTouchEnabled(true)
        XCTAssertTrue(engine.isForceTouchEnabled())
    }

    func testNewGestureKindsIngestAndSnapshot() {
        let engine = makeEngine()
        engine.ingestTrackpad(.zoomIn)
        engine.ingestTrackpad(.zoomOut)
        engine.ingestTrackpad(.smartZoom)
        engine.ingestTrackpad(.rotateCW)
        engine.ingestTrackpad(.rotateCCW)
        engine.ingestTrackpad(.scrollHorizontal)
        engine.ingestTrackpad(.scrollHorizontal)
        engine.ingestTrackpad(.scrollSession)

        let record = engine.todayRecord()
        XCTAssertEqual(record.trackpadCount(.zoomIn), 1)
        XCTAssertEqual(record.trackpadCount(.zoomOut), 1)
        XCTAssertEqual(record.trackpadCount(.smartZoom), 1)
        XCTAssertEqual(record.trackpadCount(.rotateCW), 1)
        XCTAssertEqual(record.trackpadCount(.rotateCCW), 1)
        XCTAssertEqual(record.trackpadCount(.scrollHorizontal), 2)
        XCTAssertEqual(record.trackpadCount(.scrollSession), 1)

        let snap = engine.snapshot(scope: .today, store: store)
        XCTAssertEqual(snap.trackpadCounts[.zoomIn], 1)
        XCTAssertEqual(snap.trackpadCounts[.scrollHorizontal], 2)
        XCTAssertEqual(snap.hourlyByOp[.scrollSession]?[10], 1, "新类别同样进入 24 小时分布")
    }

    /// 历史口径：方向拆分前落盘的 "zoom" 键在解码与快照中不丢失。
    func testLegacyZoomCountSurvivesDecodingAndSnapshot() {
        var legacy = DailyRecord(date: "2026-09-21")
        legacy.trackpadCounts["zoom"] = 5
        try? store.save(legacy)

        let engine = makeEngine()
        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.trackpadCounts[.zoom], 5, "历史 zoom 计数应保留并可见")
    }

    // MARK: - 存储兼容（增量字段容缺 + 白名单）

    /// 2026-09 增量字段之前落盘的 JSON（无 pressureTierCounts / pressureSumMilli）
    /// 必须能解码，缺省为空 / 0。
    func testDecodeLegacyJSONWithoutPressureFields() throws {
        let json = """
        {"date":"2026-09-01","keyCounts":{"A":2},"trackpadCounts":{"click":1,"zoom":3},
         "comboCounts":{},"buckets":[],"hourlyByOp":{},"activeSeconds":12.5}
        """
        let record = try JSONDecoder().decode(DailyRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.date, "2026-09-01")
        XCTAssertEqual(record.keyCounts["A"], 2)
        XCTAssertEqual(record.trackpadCounts["zoom"], 3)
        XCTAssertEqual(record.pressureSampleTotal, 0)
        XCTAssertEqual(record.pressureSumMilli, 0)
        XCTAssertNil(record.pressureAverage)
    }

    /// 新字段编码后必须在白名单内且可无损回环。
    func testEncodedJSONContainsPressureFieldsAndWhitelistCovers() throws {
        var record = DailyRecord(date: "2026-09-22")
        record.pressureTierCounts["deep"] = 2
        record.pressureSumMilli = 1800

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), DailyRecord.allowedEncodedKeys,
                       "新增持久化字段必须同步隐私白名单：\(json.keys.sorted())")
        XCTAssertEqual(json["pressureTierCounts"] as? [String: Int], ["deep": 2])
        XCTAssertEqual(json["pressureSumMilli"] as? Int, 1800)

        let back = try JSONDecoder().decode(DailyRecord.self, from: data)
        XCTAssertEqual(back, record)
    }

    // MARK: - 手势方向判定（GestureSessionTracker）

    func testZoomInAndOutByNetMagnification() {
        var tracker = GestureSessionTracker()
        tracker.addMagnification(0.02)
        tracker.addMagnification(0.03)
        XCTAssertEqual(tracker.finish(), [.zoomIn], "净放大 +0.05 应计 1 次放大")

        tracker.addMagnification(-0.05)
        XCTAssertEqual(tracker.finish(), [.zoomOut], "净缩小 −0.05 应计 1 次缩小")
    }

    /// 一次手势计 1 次：往复捏合（先张后合回原位）不产生计数。
    func testBouncingMagnifyBelowThresholdCountsNothing() {
        var tracker = GestureSessionTracker()
        tracker.addMagnification(0.005)
        tracker.addMagnification(-0.005)
        XCTAssertTrue(tracker.finish().isEmpty, "净变化低于 1% 阈值视为误触")

        tracker.addMagnification(0.2)
        tracker.addMagnification(-0.2)
        XCTAssertTrue(tracker.finish().isEmpty, "净变化归零的往复手势不计方向")
    }

    /// rotation 口径：自手势开始的累计角度，帧间差分累加。
    func testRotationCumulativeDeltasSplitCWAndCCW() {
        var tracker = GestureSessionTracker()
        tracker.addRotation(-10)   // 首帧：累计 −10
        tracker.addRotation(-25)   // 差分 −15
        XCTAssertEqual(tracker.finish(), [.rotateCW], "净负角度 = 顺时针")

        tracker.addRotation(5)
        tracker.addRotation(30)    // 差分 +25
        XCTAssertEqual(tracker.finish(), [.rotateCCW], "净正角度 = 逆时针")

        XCTAssertTrue(tracker.finish().isEmpty, "重复 finish 不应重复计数")
    }

    func testRotationSmallJitterIgnored() {
        var tracker = GestureSessionTracker()
        tracker.addRotation(1.0)
        tracker.addRotation(-1.0)
        XCTAssertTrue(tracker.finish().isEmpty, "净角度低于 2° 阈值视为误触")
    }

    /// 同一会话同时含缩放与旋转：两类各计 1 次。
    func testMagnifyAndRotateInSameGestureCountBoth() {
        var tracker = GestureSessionTracker()
        tracker.addMagnification(0.1)
        tracker.addRotation(-20)
        XCTAssertEqual(Set(tracker.finish()), [.zoomIn, .rotateCW])
    }

    /// 实时页「进行中」方向：随净方向即时翻转，无样本时为 nil。
    func testMagnifyDirectionSoFarForLiveDisplay() {
        var tracker = GestureSessionTracker()
        XCTAssertNil(tracker.magnifyDirectionSoFar)
        tracker.addMagnification(-0.02)
        XCTAssertEqual(tracker.magnifyDirectionSoFar, false)
        tracker.addMagnification(0.05)
        XCTAssertEqual(tracker.magnifyDirectionSoFar, true, "净方向已转放大")
        tracker.finish()
        XCTAssertNil(tracker.magnifyDirectionSoFar, "结算后回到无样本态")
    }

    // MARK: - 快照压力合并

    func testSnapshotMergesPressureAcrossDays() {
        var yesterday = DailyRecord(date: "2026-09-21")
        yesterday.pressureTierCounts = ["light": 3, "deep": 1]
        yesterday.pressureSumMilli = 2000
        try? store.save(yesterday)

        let engine = makeEngine()
        engine.ingestPressure(0.95) // 今天：deep 1，和 950

        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.pressureCount(.light), 3)
        XCTAssertEqual(snap.pressureCount(.deep), 2)
        XCTAssertEqual(snap.pressureSumMilli, 2950)
        XCTAssertEqual(snap.pressureSamples, 5)
        XCTAssertEqual(snap.pressureAverage!, 2950.0 / 5 / 1000, accuracy: 1e-9)
        XCTAssertEqual(snap.pressureDeepCount, 2)
    }

    func testCustomRangeSnapshotMergesPressure() {
        var day = DailyRecord(date: "2026-09-03")
        day.pressureTierCounts = ["medium": 4]
        day.pressureSumMilli = 2400
        try? store.save(day)

        let engine = makeEngine()
        let snap = engine.snapshot(from: "2026-09-02", to: "2026-09-04", store: store)
        XCTAssertEqual(snap.pressureCount(.medium), 4)
        XCTAssertEqual(snap.pressureSumMilli, 2400)
    }
}
