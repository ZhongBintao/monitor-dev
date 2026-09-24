import XCTest
@testable import InputscapeKit

/// 触控板增强（按压强度分布 + 触点热力图）：
/// 手指压力分档与直方图、引擎聚合、触点网格映射（96×64 与旧 24×16 迁移）、
/// 存储兼容（旧 JSON 容缺 + 白名单同步）与快照合并。
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

    // MARK: - 手指压力分档与直方图

    func testPressureTierClassificationBoundaries() {
        XCTAssertEqual(PressureTier.classify(0.0), .light)
        XCTAssertEqual(PressureTier.classify(0.24), .light)
        XCTAssertEqual(PressureTier.classify(0.25), .medium, "0.25 进入中按档（下界含）")
        XCTAssertEqual(PressureTier.classify(0.54), .medium)
        XCTAssertEqual(PressureTier.classify(0.55), .deep, "0.55 进入深按档（下界含）")
        XCTAssertEqual(PressureTier.classify(1.0), .deep)
        XCTAssertEqual(PressureTier.classify(-0.2), .light, "异常负值按轻按兜底")
    }

    /// 压力 → 直方图桶：0.05 步进，越界钳制；0.25/0.55 恰好对齐桶边界。
    func testPressureBucketIndexing() {
        XCTAssertEqual(PressureTier.bucketIndex(0.0), 0)
        XCTAssertEqual(PressureTier.bucketIndex(0.1), 2)
        XCTAssertEqual(PressureTier.bucketIndex(0.25), 5)
        XCTAssertEqual(PressureTier.bucketIndex(0.55), 11)
        XCTAssertEqual(PressureTier.bucketIndex(1.0), 19)
        XCTAssertEqual(PressureTier.bucketIndex(-0.3), 0, "负值钳到首桶")
        XCTAssertEqual(PressureTier.bucketIndex(1.7), 19, "越界钳到末桶")
    }

    /// 直方图 → 三档汇总（桶 0–4 / 5–10 / 11–19）。
    func testTierCountsFromHistogram() {
        var histogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        histogram[2] = 3   // light
        histogram[7] = 4   // medium
        histogram[13] = 5  // deep
        let tiers = PressureTier.tierCounts(in: histogram)
        XCTAssertEqual(tiers.light, 3)
        XCTAssertEqual(tiers.medium, 4)
        XCTAssertEqual(tiers.deep, 5)
    }

    // MARK: - 引擎聚合

    /// 手指按压按帧累计：直方图反映「压力 × 停留时间」，
    /// 不进 5 分钟桶、不影响活跃输入段（触点是存在而非操作）。
    func testIngestTouchPressureHistogramAndAverage() {
        let engine = makeEngine()
        engine.ingestTouchPressure(0.1)   // 桶 2
        engine.ingestTouchPressure(0.27)  // 桶 5
        engine.ingestTouchPressure(0.8)   // 桶 16

        let record = engine.todayRecord()
        XCTAssertEqual(record.touchPressureHistogram[2], 1)
        XCTAssertEqual(record.touchPressureHistogram[5], 1)
        XCTAssertEqual(record.touchPressureHistogram[16], 1)
        XCTAssertEqual(record.touchPressureSamples, 3)
        // 平均 = 桶中心 (0.125 + 0.275 + 0.825) / 3
        XCTAssertEqual(record.touchPressureAverage!, 1.225 / 3, accuracy: 1e-9)
        XCTAssertTrue(record.buckets.isEmpty, "压力样本不应进 5 分钟桶")
        XCTAssertEqual(engine.activeSecondsToday(), 0, accuracy: 0.001)
    }

    func testForceTouchClickThresholdDecoupledFromFingerTiers() {
        // Force Touch 深按判定（点击瞬间口径）与手指压力档（连续口径）
        // 值域不同，必须独立标定，不允许联动。
        XCTAssertEqual(EventMonitor.forceTouchClickThreshold, 0.9)
        XCTAssertEqual(PressureTier.deepThreshold, 0.55)
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

    // MARK: - 触点热力图（96×64）

    /// 归一化坐标 → 网格：左上角落第 0 行第 0 列，右下角落最后一格。
    func testIngestTouchpointGridMapping() {
        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.0, normalizedY: 0.0)      // 左上
        engine.ingestTouchpoint(normalizedX: 0.999, normalizedY: 0.999)  // 右下
        engine.ingestTouchpoint(normalizedX: 0.5, normalizedY: 0.5)      // 中央

        let grid = engine.todayRecord().touchGrid
        XCTAssertEqual(grid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(DailyRecord.touchGridColumns, 96)
        XCTAssertEqual(DailyRecord.touchGridRows, 64)
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

    /// 旧 24×16 网格 → 96×64 上采样：4×4 均摊、余数补齐、总量守恒，
    /// 且降采样往返无损。
    func testLegacyGridUpsampleAndDownsampleRoundtrip() {
        var legacy = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        legacy[0] = 17     // 余数场景
        legacy[100] = 32   // 整除场景
        legacy[383] = 1

        let upsampled = DailyRecord.upsampleLegacyTouchGrid(legacy)
        XCTAssertEqual(upsampled.count, DailyRecord.touchGridCells)
        XCTAssertEqual(upsampled.reduce(0, +), 50, "上采样必须守恒总计数")

        // 旧格 0 的 4×4 块（新网格 rows 0–3 × cols 0–3）：17 = 1×16 + 1
        // → 按块顺序首格 2，其余 1
        XCTAssertEqual(upsampled[0], 2)
        XCTAssertEqual(upsampled[1], 1)
        XCTAssertEqual(upsampled[96], 1, "第二行首格属于旧格 0 的块")
        XCTAssertEqual(upsampled[3 * 96 + 3], 1, "块内最后一格")

        let downsampled = DailyRecord.downsampleTouchGridToLegacy(upsampled)
        XCTAssertEqual(downsampled, legacy, "上采样 → 降采样必须还原旧网格")
    }

    /// 快照合并多天触点网格（今天 + 新格式历史 + 旧 384 格自动迁移上采样）。
    func testSnapshotMergesTouchGridAcrossDays() {
        var yesterday = DailyRecord(date: "2026-09-21")
        yesterday.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        yesterday.touchGrid[3] = 4
        try? store.save(yesterday)

        var legacyDay = DailyRecord(date: "2026-09-20")
        legacyDay.touchGrid = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        legacyDay.touchGrid[3] = 8 // 旧 24×16 格式落盘（row 0, col 3）
        try? store.save(legacyDay)

        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.9, normalizedY: 0.9) // 今天某格 +1

        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.touchGrid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(snap.touchGrid[3], 4, "新格式历史日应直接逐格合并")
        // 旧格 3（row 0, col 3）→ 新网格块 rows 0–3 × cols 12–15，
        // 8 = 0×16 + 8 → 块内按顺序前 8 格各 1
        XCTAssertEqual(snap.touchGrid[12], 1, "旧格 3 上采样块首格")
        XCTAssertEqual(snap.touchGrid[15], 1, "旧格 3 上采样块（row 0 末列）")
        XCTAssertEqual(snap.touchGrid[12 + 96], 1, "旧格 3 上采样块（row 1 首列）")
        XCTAssertEqual(snap.touchTotal, 4 + 8 + 1, "总触碰数 = 新格式历史 + 旧格式历史 + 今天")
        XCTAssertEqual(snap.touchPeak?.count, 4, "最热格为新格式历史日的 index 3")
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

    /// 2026-09 增量字段之前落盘的 JSON（无 touchGrid / touchPressureHistogram）
    /// 必须能解码，缺省为空；旧 24×16 网格解码时自动上采样。
    func testDecodeLegacyJSONWithoutNewFields() throws {
        let json = """
        {"date":"2026-09-01","keyCounts":{"A":2},"trackpadCounts":{"click":1,"zoom":3},
         "comboCounts":{},"buckets":[],"hourlyByOp":{},"activeSeconds":12.5}
        """
        let record = try JSONDecoder().decode(DailyRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.date, "2026-09-01")
        XCTAssertEqual(record.keyCounts["A"], 2)
        XCTAssertEqual(record.trackpadCounts["zoom"], 3)
        XCTAssertEqual(record.touchGrid, [])
        XCTAssertEqual(record.touchPressureHistogram, [])
        XCTAssertNil(record.touchPressureAverage)
    }

    /// 旧 384 格 touchGrid 的落盘 JSON 解码后自动迁移为 6144 格。
    func testDecodeLegacyGridMigratesTo96x64() throws {
        var legacy = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        legacy[10] = 33
        let legacyJSONData = try JSONEncoder().encode(DailyRecord(date: "2026-09-01", touchGrid: legacy))
        let json = String(data: legacyJSONData, encoding: .utf8)!

        let record = try JSONDecoder().decode(DailyRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.touchGrid.count, DailyRecord.touchGridCells, "旧网格应自动迁移为 96×64")
        XCTAssertEqual(record.touchGrid.reduce(0, +), 33, "迁移必须守恒总计数")
        let downsampled = DailyRecord.downsampleTouchGridToLegacy(record.touchGrid)
        XCTAssertEqual(downsampled[10], 33, "降采样后旧格位置计数不变")
    }

    /// 新字段编码后必须在白名单内且可无损回环。
    func testEncodedJSONContainsNewFieldsAndWhitelistCovers() throws {
        var record = DailyRecord(date: "2026-09-22")
        record.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        record.touchGrid[5] = 7
        record.touchPressureHistogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        record.touchPressureHistogram[9] = 42

        let data = try JSONEncoder().encode(record)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(json.keys), DailyRecord.allowedEncodedKeys,
                       "新增持久化字段必须同步隐私白名单：\(json.keys.sorted())")
        XCTAssertFalse(json.keys.contains("pressureTierCounts"), "废弃字段不得再编码")
        XCTAssertFalse(json.keys.contains("pressureSumMilli"), "废弃字段不得再编码")
        XCTAssertEqual((json["touchGrid"] as? [Int])?.count, DailyRecord.touchGridCells)
        XCTAssertEqual((json["touchPressureHistogram"] as? [Int])?.count, PressureTier.histogramBuckets)

        let back = try JSONDecoder().decode(DailyRecord.self, from: data)
        XCTAssertEqual(back, record)
    }

    // MARK: - 快照合并

    func testSnapshotMergesPressureHistogramAcrossDays() {
        var yesterday = DailyRecord(date: "2026-09-21")
        yesterday.touchPressureHistogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        yesterday.touchPressureHistogram[3] = 6
        try? store.save(yesterday)

        let engine = makeEngine()
        engine.ingestTouchPressure(0.8) // 今天：桶 16 +1

        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.touchPressureHistogram[3], 6)
        XCTAssertEqual(snap.touchPressureHistogram[16], 1)
        XCTAssertEqual(snap.touchPressureSamples, 7)
        let tiers = snap.touchPressureTiers
        XCTAssertEqual(tiers.light, 6)
        XCTAssertEqual(tiers.deep, 1)
    }

    func testCustomRangeSnapshotMergesPressureHistogram() {
        var day = DailyRecord(date: "2026-09-03")
        day.touchPressureHistogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        day.touchPressureHistogram[8] = 4
        try? store.save(day)

        let engine = makeEngine()
        let snap = engine.snapshot(from: "2026-09-02", to: "2026-09-04", store: store)
        XCTAssertEqual(snap.touchPressureHistogram[8], 4)
        XCTAssertEqual(snap.touchPressureSamples, 4)
    }
}
