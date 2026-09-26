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
        // 轻按中位 (0.49+0.50)/2 = 0.495 / 重按中位 (1.39+1.40)/2 = 1.395
        // → 分界 0.945。
        XCTAssertEqual(result.lightMedian, 0.495, accuracy: 1e-9)
        XCTAssertEqual(result.heavyMedian, 1.395, accuracy: 1e-9)
        XCTAssertEqual(result.threshold, 0.945, accuracy: 1e-9)
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

        // 悬停（stage 0）与无效值不采。
        let hover = PressureCalibrationSession()
        hover.beginLightCollection()
        hover.recordStage(0)
        hover.recordContactPressure(0.5)
        hover.recordStage(1)
        hover.recordContactPressure(0)
        XCTAssertEqual(hover.lightSampleCount, 0)
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
