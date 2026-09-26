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

    /// 两档分界：< 1.0 轻按，≥ 1.0 重按（zTotal 电容总量实测可超 1）。
    func testPressureTierClassificationBoundaries() {
        XCTAssertEqual(PressureTier.classify(0.0), .light)
        XCTAssertEqual(PressureTier.classify(0.55), .light, "旧中按区间并入轻按")
        XCTAssertEqual(PressureTier.classify(0.99), .light)
        XCTAssertEqual(PressureTier.classify(1.0), .heavy, "1.0 进入重按档（下界含）")
        XCTAssertEqual(PressureTier.classify(1.7), .heavy)
        XCTAssertEqual(PressureTier.classify(2.0), .heavy)
        XCTAssertEqual(PressureTier.classify(-0.2), .light, "异常负值按轻按兜底")
    }

    /// 压力 → 直方图桶：40 桶 × 0.05（量程 0–2），越界钳制；
    /// 1.0 恰落桶 20（重按首桶）。0.05 非二进制精确值，索引用 rounded 防浮点错桶。
    func testPressureBucketIndexing() {
        XCTAssertEqual(PressureTier.bucketIndex(0.0), 0)
        XCTAssertEqual(PressureTier.bucketIndex(0.1), 2)
        XCTAssertEqual(PressureTier.bucketIndex(0.25), 5)
        XCTAssertEqual(PressureTier.bucketIndex(0.55), 11)
        XCTAssertEqual(PressureTier.bucketIndex(1.0), 20, "1.0 = 重按首桶")
        XCTAssertEqual(PressureTier.bucketIndex(1.55), 31)
        XCTAssertEqual(PressureTier.bucketIndex(2.0), 39, "量程上界钳制末桶")
        XCTAssertEqual(PressureTier.bucketIndex(-0.3), 0, "负值钳到首桶")
        XCTAssertEqual(PressureTier.bucketIndex(3.7), 39, "越界钳到末桶")
    }

    /// 直方图 → 两档汇总（桶 0–19 轻 / 20–39 重）。
    func testTierCountsFromHistogram() {
        var histogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        histogram[2] = 3    // light
        histogram[19] = 4   // light（0.95–1.0 区间）
        histogram[20] = 5   // heavy（1.0–1.05 区间）
        histogram[33] = 2   // heavy
        let tiers = PressureTier.tierCounts(in: histogram)
        XCTAssertEqual(tiers.light, 7)
        XCTAssertEqual(tiers.heavy, 7)
    }

    /// 旧 20 桶直方图（量程 0–1）→ 40 桶：零填充迁移无损（桶 i 压力区间一致）。
    func testLegacyHistogramPadding() {
        var legacy = Array(repeating: 0, count: PressureTier.legacyHistogramBuckets)
        legacy[3] = 6
        legacy[16] = 1
        let padded = PressureTier.padLegacyHistogram(legacy)
        XCTAssertEqual(padded.count, PressureTier.histogramBuckets)
        XCTAssertEqual(padded[3], 6)
        XCTAssertEqual(padded[16], 1)
        XCTAssertEqual(padded.suffix(20).reduce(0, +), 0, "后半（0–1 区间外）应为空")
        XCTAssertEqual(padded.reduce(0, +), 7, "总样本数守恒")
        XCTAssertEqual(PressureTier.padLegacyHistogram(padded).count, PressureTier.histogramBuckets,
                       "新格式数据重复填充必须原样返回")
    }

    // MARK: - 手掌误触防护

    /// 手掌判定：接触椭圆任一轴达到手掌量级（mm）即过滤。
    /// 手指接触椭圆长轴 ~9–13mm，手掌显著更大。
    func testPalmRejectionHeuristics() {
        XCTAssertFalse(TouchpointMonitor.isPalm(majorAxis: 10, minorAxis: 7), "典型手指接触")
        XCTAssertFalse(TouchpointMonitor.isPalm(majorAxis: 13, minorAxis: 9), "大手指接触")
        XCTAssertTrue(TouchpointMonitor.isPalm(majorAxis: 25, minorAxis: 12), "长轴达手掌量级")
        XCTAssertTrue(TouchpointMonitor.isPalm(majorAxis: 11, minorAxis: 16), "短轴达手掌量级")
        XCTAssertTrue(TouchpointMonitor.isPalm(majorAxis: 30, minorAxis: 20), "典型手掌")
        XCTAssertEqual(TouchpointMonitor.palmMajorAxisThreshold, 20.0)
        XCTAssertEqual(TouchpointMonitor.palmMinorAxisThreshold, 15.0)
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

    /// 轻/重分界阈值参数化：默认 1.0 恰在桶 19/20 之间；
    /// 校准阈值（如 0.87）按桶中心动态切分，历史直方图无需重写。
    func testTierCountsRespectsCustomThreshold() {
        var histogram = Array(repeating: 0, count: PressureTier.histogramBuckets)
        histogram[16] = 3   // 桶中心 0.825
        histogram[17] = 5   // 桶中心 0.875
        histogram[25] = 2   // 桶中心 1.275

        // 默认 1.0：0.825/0.875 均属轻按，1.275 属重按。
        let defaultTiers = PressureTier.tierCounts(in: histogram)
        XCTAssertEqual(defaultTiers.light, 8)
        XCTAssertEqual(defaultTiers.heavy, 2)

        // 校准分界 0.87：0.825 归轻，0.875/1.275 归重。
        let calibrated = PressureTier.tierCounts(in: histogram, threshold: 0.87)
        XCTAssertEqual(calibrated.light, 3)
        XCTAssertEqual(calibrated.heavy, 7)

        // 更低分界 0.8：三桶全部归重。
        let aggressive = PressureTier.tierCounts(in: histogram, threshold: 0.8)
        XCTAssertEqual(aggressive.light, 0)
        XCTAssertEqual(aggressive.heavy, 10)
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

    // MARK: - 触点热力图（24×16）

    /// 归一化坐标 → 网格：左上角落第 0 行第 0 列，右下角落最后一格。
    func testIngestTouchpointGridMapping() {
        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.0, normalizedY: 0.0)      // 左上
        engine.ingestTouchpoint(normalizedX: 0.999, normalizedY: 0.999)  // 右下
        engine.ingestTouchpoint(normalizedX: 0.5, normalizedY: 0.5)      // 中央

        let grid = engine.todayRecord().touchGrid
        XCTAssertEqual(grid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(DailyRecord.touchGridColumns, 24)
        XCTAssertEqual(DailyRecord.touchGridRows, 16)
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

    /// 旧 96×64 网格 → 24×16：4×4 块求和、总量守恒、落点正确
    /// （一次性迁移路径，2026-09-24 当天的 6144 格落盘数据保留不丢）。
    func testLegacy96GridDownsampleMigration() {
        var legacy = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        // 新格 (0,0) 的旧 4×4 块（legacy rows 0–3 × cols 0–3）：17 次全在 legacy[0]。
        legacy[0] = 17
        // 新格 (0,1) 的旧块（legacy cols 4–7）：32 次全在其首格 legacy[4]。
        legacy[4] = 32
        // 旧网格最后一格 (row 63, col 95) → 新网格最后一格 (row 15, col 23)。
        legacy[DailyRecord.legacyTouchGridCells - 1] = 1

        let downsampled = DailyRecord.downsampleLegacyTouchGrid(legacy)
        XCTAssertEqual(downsampled.count, DailyRecord.touchGridCells)
        XCTAssertEqual(downsampled.reduce(0, +), 50, "降采样必须守恒总计数")
        XCTAssertEqual(downsampled[0], 17, "旧块 (rows 0–3 × cols 0–3) → 新格 (0,0)")
        XCTAssertEqual(downsampled[1], 32, "旧块 (rows 0–3 × cols 4–7) → 新格 (0,1)")
        XCTAssertEqual(downsampled[DailyRecord.touchGridCells - 1], 1, "右下角落点对应")
        // 长度不符时返回空网格（防御），不污染正常数据。
        XCTAssertEqual(DailyRecord.downsampleLegacyTouchGrid([1, 2, 3]),
                       Array(repeating: 0, count: DailyRecord.touchGridCells))
    }

    /// 快照合并多天触点网格（今天 + 24×16 新格式历史 + 旧 96×64 自动迁移）。
    func testSnapshotMergesTouchGridAcrossDays() {
        var yesterday = DailyRecord(date: "2026-09-21")
        yesterday.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        yesterday.touchGrid[3] = 4
        try? store.save(yesterday)

        var legacyDay = DailyRecord(date: "2026-09-20")
        legacyDay.touchGrid = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        legacyDay.touchGrid[3] = 8 // 旧 96×64 格式（row 0, col 3）→ 新格 (0,0) 的块
        try? store.save(legacyDay)

        let engine = makeEngine()
        engine.ingestTouchpoint(normalizedX: 0.9, normalizedY: 0.9) // 今天 (row 21, col 21) +1

        let snap = engine.snapshot(scope: .last7Days, store: store)
        XCTAssertEqual(snap.touchGrid.count, DailyRecord.touchGridCells)
        XCTAssertEqual(snap.touchGrid[3], 4, "新格式历史日直接逐格合并")
        XCTAssertEqual(snap.touchGrid[0], 8, "旧 96×64 落盘日应降采样合并到新格 (0,0)")
        XCTAssertEqual(snap.touchTotal, 4 + 8 + 1, "总触碰数 = 新格式历史 + 旧格式历史 + 今天")
        XCTAssertEqual(snap.touchPeak?.count, 8, "最热格为旧格式迁移后的 index 0")
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
    /// 必须能解码，缺省为空。
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

    /// 旧 20 桶压力直方图落盘 JSON 解码后自动零填充为 40 桶。
    func testDecodeLegacyHistogramPadsTo40Buckets() throws {
        var legacy = Array(repeating: 0, count: PressureTier.legacyHistogramBuckets)
        legacy[9] = 42
        let data = try JSONEncoder().encode(DailyRecord(date: "2026-09-01", touchPressureHistogram: legacy))
        let record = try JSONDecoder().decode(DailyRecord.self, from: data)
        XCTAssertEqual(record.touchPressureHistogram.count, PressureTier.histogramBuckets)
        XCTAssertEqual(record.touchPressureHistogram[9], 42)
        XCTAssertEqual(record.touchPressureSamples, 42, "迁移必须守恒总样本数")
    }

    /// 旧 6144 格 touchGrid 的落盘 JSON 解码后自动迁移为 384 格。
    func testDecodeLegacy96GridMigratesTo24x16() throws {
        var legacy = Array(repeating: 0, count: DailyRecord.legacyTouchGridCells)
        legacy[10] = 33
        let legacyJSONData = try JSONEncoder().encode(DailyRecord(date: "2026-09-01", touchGrid: legacy))
        let json = String(data: legacyJSONData, encoding: .utf8)!

        let record = try JSONDecoder().decode(DailyRecord.self, from: Data(json.utf8))
        XCTAssertEqual(record.touchGrid.count, DailyRecord.touchGridCells, "旧网格应自动迁移为 24×16")
        XCTAssertEqual(record.touchGrid.reduce(0, +), 33, "迁移必须守恒总计数")
        // 6144 格 index 10 = row 0, col 10 → 新网格 (row 0, col 2)。
        XCTAssertEqual(record.touchGrid[2], 33)
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
        XCTAssertEqual(tiers.light, 7, "0.8 < 1.0 属轻按档")
        XCTAssertEqual(tiers.heavy, 0)
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
