import XCTest
@testable import InputscapeKit

/// 系统压力档跟踪（点击重/轻判定的权威依据）与按压校准会话。
final class PressureStageTests: XCTestCase {

    // MARK: - PressureStageTracker

    /// 时间窗内最大 stage：重按（stage 2）后点击 → 2；纯轻按 → 1；
    /// 无信号（鼠标）→ nil → 普通点击。
    func testMaxStageWithinWindow() {
        var tracker = PressureStageTracker(window: 0.5)
        tracker.record(stage: 1, at: 100.0)
        XCTAssertEqual(tracker.maxStage(of: 100.1), 1)
        tracker.record(stage: 2, at: 100.2)
        XCTAssertEqual(tracker.maxStage(of: 100.25), 2, "窗口内出现过 stage 2 → 重按")
        XCTAssertNil(tracker.maxStage(of: 100.75), "0.55s 后全部出窗 → 无信号")
        tracker.record(stage: 1, at: 101.0)
        XCTAssertEqual(tracker.maxStage(of: 101.1), 1, "新的轻按信号 → 轻按")
    }

    /// 判定窗口外的旧 stage 不影响新点击（连续两次点击去耦）。
    func testStaleStageDoesNotLeakIntoNextClick() {
        var tracker = PressureStageTracker(window: 0.5)
        tracker.record(stage: 2, at: 100.0)
        XCTAssertNil(tracker.maxStage(of: 100.9), "0.9s 后旧重按信号失效")
    }

    /// 容量裁剪：长流不无限增长，判定语义不变。
    func testRingCapacityPruning() {
        var tracker = PressureStageTracker(window: 0.5)
        var t = 0.0
        for _ in 0..<200 {
            tracker.record(stage: 1, at: t)
            t += 0.01
        }
        tracker.record(stage: 2, at: t)
        XCTAssertEqual(tracker.maxStage(of: t), 2)
    }

    // MARK: - PressureCalibrationSession

    /// @MainActor 会话：测试标 MainActor。
    @MainActor
    func testCalibrationLearnsThresholdFromLabeledSamples() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        // 采集阶段系统判定实时标注：stage 1 → 轻，stage 2 → 重。
        // 用索引构造样本，避免浮点 stride 的数量歧义。
        session.recordStage(1)
        for i in 0..<40 {
            session.recordContactPressure(0.30 + Double(i) * 0.01)
        }
        session.recordStage(2)
        for i in 0..<40 {
            session.recordContactPressure(1.20 + Double(i) * 0.01)
        }
        XCTAssertEqual(session.lightSampleCount, 40)
        XCTAssertEqual(session.heavySampleCount, 40)

        let result = session.compute()
        XCTAssertTrue(result.isSuccess, "分离度 \(result.separation) 应达标")
        // 轻按中位 (0.49+0.50)/2 = 0.495；重按 P90（nearest-rank，
        // 40 样本取第 36 小）= 1.20 + 35×0.01 = 1.55 → 分界 1.0225。
        XCTAssertEqual(result.lightMedian, 0.495, accuracy: 1e-9)
        XCTAssertEqual(result.heavyP90, 1.55, accuracy: 1e-9)
        XCTAssertEqual(result.threshold, 1.0225, accuracy: 1e-9)
    }

    /// 交叉污染防御：轻按阶段用户误重按，样本按实时 stage 归重类。
    @MainActor
    func testSamplesLabeledByLiveStageNotPhase() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        session.recordStage(1)
        session.recordContactPressure(0.3)
        session.recordStage(2)   // 用户此刻重按
        session.recordContactPressure(1.4)
        session.recordStage(1)
        session.recordContactPressure(0.35)
        let result = session.compute()
        XCTAssertEqual(result.lightSamples, 2)
        XCTAssertEqual(result.heavySamples, 1)
    }

    /// 分离不足 / 样本不足 → isSuccess = false（调用方保留默认阈值）。
    @MainActor
    func testCalibrationFailurePaths() async {
        // 分离不足：两类中位差 < 0.2。
        let close = PressureCalibrationSession()
        close.beginLightCollection()
        close.recordStage(1)
        for _ in 0..<40 { close.recordContactPressure(0.50) }
        close.recordStage(2)
        for _ in 0..<40 { close.recordContactPressure(0.60) }
        XCTAssertFalse(close.compute().isSuccess, "中位差 0.1 < 0.2 应判失败")

        // 样本不足：分离够但每类 < 30 帧。
        let sparse = PressureCalibrationSession()
        sparse.beginLightCollection()
        sparse.recordStage(1)
        for _ in 0..<5 { sparse.recordContactPressure(0.3) }
        sparse.recordStage(2)
        for _ in 0..<40 { sparse.recordContactPressure(1.3) }
        XCTAssertFalse(sparse.compute().isSuccess, "轻按 5 帧不足")

        // 无效值（pressure ≤ 0）不采；stage 0（接触中、未达重按门限）
        // 按契约「stage < 2 轻」归轻类，不再丢弃。
        let invalid = PressureCalibrationSession()
        invalid.beginLightCollection()
        invalid.recordStage(1)
        invalid.recordContactPressure(0)
        invalid.recordContactPressure(-0.1)
        XCTAssertEqual(invalid.lightSampleCount, 0, "无效值不采")
        invalid.recordStage(0)
        invalid.recordContactPressure(0.5)
        XCTAssertEqual(invalid.lightSampleCount, 1, "stage 0 未达重按门限 → 轻类")
    }

    /// 流式投递 stage 0 的机型（接触期间持续 stage 0/1/2 遥测）：
    /// 轻按阶段 stage 恒 0，样本必须入轻类——此前 stage 0 被丢弃，
    /// 轻按阶段 0 帧（实测缺陷的机型差异面）。
    @MainActor
    func testStageZeroSamplesCountAsLightWhenStreamAlive() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        session.recordStage(0)   // 信号存活，接触压力未达重按门限
        for _ in 0..<40 { session.recordContactPressure(0.42) }
        session.beginHeavyCollection()
        session.recordStage(2)
        for _ in 0..<40 { session.recordContactPressure(1.42) }
        XCTAssertEqual(session.lightSampleCount, 40, "stage 0 样本应入轻类")
        XCTAssertEqual(session.heavySampleCount, 40)
        XCTAssertTrue(session.compute().isSuccess)
    }

    // MARK: - 触点复合标识

    /// (handID, fingerID) 复合键：帧内唯一、跨手不撞键（多指显示修复）。
    func testTouchSampleCompositeID() {
        let fingerA = TouchSample(fingerID: 3, handID: 1, x: 0.1, y: 0.1,
                                  pressure: 0.5, majorAxis: 10, minorAxis: 8, angle: 0)
        let fingerB = TouchSample(fingerID: 4, handID: 1, x: 0.5, y: 0.5,
                                  pressure: 0.5, majorAxis: 10, minorAxis: 8, angle: 0)
        let otherHand = TouchSample(fingerID: 3, handID: 2, x: 0.9, y: 0.9,
                                    pressure: 0.5, majorAxis: 10, minorAxis: 8, angle: 0)
        XCTAssertNotEqual(fingerA.touchID, fingerB.touchID, "同手不同指不得撞键")
        XCTAssertNotEqual(fingerA.touchID, otherHand.touchID, "跨手同 ID 不得撞键")
        XCTAssertEqual(fingerA.touchID, fingerA.touchID, "同指跨帧键稳定")
    }

    // MARK: - 校准标注回退（系统压力档信号缺失）

    /// 本机不投递 type 34（全程无 stage 事件）→ 按采集阶段标注：
    /// 轻按阶段的样本入轻类、重按阶段入重类，校准可正常完成。
    @MainActor
    func testPhaseFallbackLabelingWhenStageStreamMissing() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        // 全程不调用 recordStage —— stageStreamAlive 恒 false。
        XCTAssertFalse(session.stageStreamAlive)
        for _ in 0..<40 { session.recordContactPressure(0.40) }
        session.beginHeavyCollection()
        for _ in 0..<40 { session.recordContactPressure(1.40) }

        XCTAssertEqual(session.lightSampleCount, 40, "轻按阶段样本应入轻类")
        XCTAssertEqual(session.heavySampleCount, 40, "重按阶段样本应入重类")
        let result = session.compute()
        XCTAssertTrue(result.isSuccess)
        XCTAssertEqual(result.threshold, 0.9, accuracy: 1e-9)
    }

    /// stage 信号存活时按实时 stage 标注（权威），跨手/按错阶段不污染。
    @MainActor
    func testStageLabelingPreferredWhenStreamAlive() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        session.recordStage(1)   // 信号存活（刚收到）
        for _ in 0..<40 { session.recordContactPressure(0.40) }
        session.beginHeavyCollection()
        session.recordStage(2)
        for _ in 0..<40 { session.recordContactPressure(1.40) }
        XCTAssertTrue(session.stageStreamAlive)
        XCTAssertEqual(session.lightSampleCount, 40)
        XCTAssertEqual(session.heavySampleCount, 40)
        XCTAssertTrue(session.compute().isSuccess)
    }

    /// 重按代表值必须抗占空比污染（实测校准失败的根因）：
    /// 无 stage 信号机型按阶段标注时，重按阶段按压间歇的基线接触
    /// （zTotal ≈ 0.85 稳态）占样本多数（本例 80%），中位数被基线
    /// 拖死（0.85 − 0.75 = 0.1 < 0.2 恒失败）；P90 落在按压峰值簇内，
    /// 校准可正常完成。落盘数据佐证：正常使用全天峰值 ≤0.95，
    /// 重按 1.2–1.95（2026-09-24/26 直方图）。
    @MainActor
    func testHeavyP90ResistsDutyCycleContamination() async {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        for _ in 0..<40 { session.recordContactPressure(0.75) }   // 轻按稳态
        session.beginHeavyCollection()
        for _ in 0..<80 { session.recordContactPressure(0.85) }   // 按压间歇基线
        for i in 0..<20 { session.recordContactPressure(1.50 + Double(i) * 0.01) } // 峰值 1.50–1.69

        let result = session.compute()
        // P90（nearest-rank，100 样本取第 90 小）= 1.50 + 9×0.01 = 1.59。
        XCTAssertEqual(result.heavyP90, 1.59, accuracy: 1e-9)
        XCTAssertEqual(result.lightMedian, 0.75, accuracy: 1e-9)
        XCTAssertEqual(result.threshold, 1.17, accuracy: 1e-9)
        XCTAssertTrue(result.isSuccess, "分离度 \(result.separation) 应达标（中位数口径为 0.1，必挂）")
    }

    // MARK: - PressureCalibrationStore

    /// 持久化回环 + 清除（独立 suite，不污染宿主 defaults）。
    func testCalibrationStorePersistence() {
        let name = "PressureStageTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }

        var store = PressureCalibrationStore()
        XCTAssertFalse(store.isActive)

        store.threshold = 0.895
        store.calibratedAt = Date(timeIntervalSince1970: 1_789_000_000)
        store.useCalibration = true
        store.save(defaults: defaults)

        let loaded = PressureCalibrationStore.load(defaults: defaults)
        XCTAssertEqual(loaded.threshold ?? 0, 0.895, accuracy: 1e-9)
        XCTAssertEqual(loaded.calibratedAt, store.calibratedAt)
        XCTAssertTrue(loaded.isActive)

        var cleared = loaded
        cleared.clear()
        XCTAssertNil(cleared.threshold)
        XCTAssertFalse(cleared.isActive)
        cleared.save(defaults: defaults)
        XCTAssertNil(PressureCalibrationStore.load(defaults: defaults).threshold)
    }
}
