import XCTest
@testable import InputscapeKit

/// 触控板增强（点击压力分档 + 触点热力图）：
/// 压力分档阈值、引擎聚合、触点网格映射、存储兼容
/// （旧 JSON 容缺 + 白名单同步）与快照合并。
/// 手势口径已收缩为官方事件直计（smartZoom/swipe），无自定义识别逻辑可测。
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

    /// 手势收缩后保留的官方事件直计类别照常进引擎与快照。
    func testOfficialGestureKindsIngestAndSnapshot() {
        let engine = makeEngine()
        engine.ingestTrackpad(.smartZoom)
        engine.ingestTrackpad(.swipe)
        engine.ingestTrackpad(.click)

        let record = engine.todayRecord()
        XCTAssertEqual(record.trackpadCount(.smartZoom), 1)
        XCTAssertEqual(record.trackpadCount(.swipe), 1)
        XCTAssertEqual(record.trackpadCount(.click), 1)

        let snap = engine.snapshot(scope: .today, store: store)
        XCTAssertEqual(snap.trackpadCounts[.smartZoom], 1)
        XCTAssertEqual(snap.trackpadCounts[.swipe], 1)
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

    // MARK: - 触点热力图

    /// 归一化坐标 → 网格：左上角落第 0 行第 0 列，右下角落最后一格。
    func testIngestTouchpointGridMapping() {
        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.0, normalizedY: 0.0)      // 左上
        engine.ingestTouchpoint(normalizedX: 0.999, normalizedY: 0.999)  // 右下
        engine.ingestTouchpoint(normalizedX: 0.5, normalizedY: 0.5)      // 中央

        let grid = engine.todayRecord().touchGrid
        XCTAssertEqual(grid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(grid[0], 1, "左上角触点应落第 0 行第 0 列")
        let last = DailyRecord.touchGridCells - 1
        XCTAssertEqual(grid[last], 1, "右下角触点应落最后一格")
        let center = (DailyRecord.touchGridRows / 2) * DailyRecord.touchGridColumns
            + DailyRecord.touchGridColumns / 2
        XCTAssertEqual(grid[center], 1, "中央触点应落网格中部")
    }

    /// 越界坐标被钳制在网格内；触点不进桶、不延长活跃输入段。
    func testIngestTouchpointClampsOutOfRangeAndSkipsBuckets() {
        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: -0.5, normalizedY: 1.7) // → 钳到 (第 0 列, 最后一行)
        engine.ingestTouchpoint(normalizedX: 2.0, normalizedY: -1.0) // → 钳到 (最后一列, 第 0 行)

        let grid = engine.todayRecord().touchGrid
        let lastRowStart = (DailyRecord.touchGridRows - 1) * DailyRecord.touchGridColumns
        XCTAssertEqual(grid[lastRowStart], 1, "(-0.5, 1.7) 应钳到最后一行第 0 列")
        XCTAssertEqual(grid[DailyRecord.touchGridColumns - 1], 1, "(2.0, -1.0) 应钳到第 0 行最后一列")
        XCTAssertTrue(engine.todayRecord().buckets.isEmpty, "触点不应进 5 分钟桶")
        XCTAssertEqual(engine.activeSecondsToday(), 0, accuracy: 0.001, "触点不应延长活跃输入段")
    }

    /// 快照合并多天触点网格（今天 + 落盘历史）。
    func testSnapshotMergesTouchGridAcrossDays() {
        var yesterday = DailyRecord(date: "2026-09-21")
        yesterday.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        yesterday.touchGrid[3] = 4
        try? store.save(yesterday)

        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.9, normalizedY: 0.9) // 今天某格 +1

        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.touchGrid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(snap.touchGrid[3], 4, "历史日网格应合并")
        XCTAssertEqual(snap.touchTotal, 5, "总触碰数 = 历史 + 今天")
        XCTAssertEqual(snap.touchPeak?.count, 4, "最热格来自历史日")
    }

    func testSnapshotTouchCountAndEmptyGrid() {
        let engine = makeEngine()
        let snap = engine.snapshot(scope: .today, store: store)
        XCTAssertEqual(snap.touchTotal, 0)
        XCTAssertNil(snap.touchPeak)
        XCTAssertEqual(snap.touchCount(row: 0, column: 0), 0)
        XCTAssertEqual(snap.touchCount(row: -1, column: 0), 0, "越界读取返回 0")
        XCTAssertEqual(snap.touchCount(row: 0, column: 999), 0, "越界读取返回 0")
    }

    // MARK: - 存储兼容（增量字段容缺 + 白名单）

    /// 2026-09 增量字段之前落盘的 JSON（无 pressure / touchGrid 字段）
    /// 必须能解码，缺省为空 / 0。
    func testDecodeLegacyJSONWithoutNewFields() throws {
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
        XCTAssertEqual(record.touchGrid, [])
        XCTAssertNil(record.pressureAverage)
    }

    /// 新字段编码后必须在白名单内且可无损回环。
    func testEncodedJSONContainsNewFieldsAndWhitelistCovers() throws {
        var record = DailyRecord(date: "2026-09-22")
        record.pressureTierCounts["deep"] = 2
        record.pressureSumMilli = 1800
        record.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        record.touchGrid[5] = 7

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), DailyRecord.allowedEncodedKeys,
                       "新增持久化字段必须同步隐私白名单：\(json.keys.sorted())")
        XCTAssertEqual(json["pressureTierCounts"] as? [String: Int], ["deep": 2])
        XCTAssertEqual(json["pressureSumMilli"] as? Int, 1800)
        XCTAssertEqual((json["touchGrid"] as? [Int])?.count, DailyRecord.touchGridCells)

        let back = try JSONDecoder().decode(DailyRecord.self, from: data)
        XCTAssertEqual(back, record)
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
