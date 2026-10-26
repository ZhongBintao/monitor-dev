import Testing
import Foundation
@testable import InputscapeCore

/// Phase 0 信号实验室：录制分阶段打标签 + 评估纯函数。
/// 真机 fixture 录得后追加为回归用例（REFACTOR_PLAN.md §8）。
struct SignalLabTests {

    // MARK: - 按键重复

    private func keyRecording(_ events: [(String, Bool)]) -> LabRecording {
        LabRecording(protocolID: LabProtocol.keyRepeat.id, recordedAt: Date(),
                     phases: [.init(stepID: "hold", start: 0, end: 100)], frames: [],
                     keys: events.enumerated().map { LabKeyEvent(t: Double($0.offset), keyID: $0.element.0, isRepeat: $0.element.1) },
                     clicks: [])
    }

    @Test func testKeyRepeatPassesWhenHoldsCountOnce() {
        var events: [(String, Bool)] = []
        for _ in 0..<5 {
            events.append(("Delete", false))
            events += Array(repeating: ("Delete", true), count: 20)
        }
        let v = LabEvaluation.keyRepeat(keyRecording(events))
        #expect(v.passed)
        #expect(v.lines[1].contains("105"), "v1 口径应把重复也计入：5 + 100")
    }

    @Test func testKeyRepeatFailsWithoutRepeats() {
        let v = LabEvaluation.keyRepeat(keyRecording(Array(repeating: ("Delete", false), count: 5)))
        #expect(!(v.passed), "没有重复事件说明按住太短或标志无效")
    }

    @Test func testKeyRepeatFailsOnWrongPressCount() {
        var events: [(String, Bool)] = []
        for _ in 0..<4 { events.append(("Delete", false)); events.append(("Delete", true)) }
        #expect(!(LabEvaluation.keyRepeat(keyRecording(events)).passed))
    }

    @Test func testKeyRepeatEmptyRecording() {
        #expect(!(LabEvaluation.keyRepeat(keyRecording([])).passed))
    }

    // MARK: - 压力字段

    /// 合成录制（125Hz）：rest 0–6 / tap 6–14 / push 14–20 / click 20–30 / force 30–42。
    /// - tap：每次轻点是独立接触段（段间无帧 = 手指抬起），并像轻点开关那样产生点击事件；
    /// - click：手指常驻，按下时压力冲到 click 峰值并产生点击事件；
    /// - force：手指常驻，压力冲到 force 峰值，**不产生**新的点击事件（深按真实行为）。
    /// zTotal 恒约 0.9（模拟 v1 的电容饱和）。
    private func pressureRecording(rest: Double, tap: Double, push: Double, click: Double, force: Double,
                                   count: Int = 5) -> LabRecording {
        var frames: [LabFrame] = []
        var clicks: [LabClick] = []
        func frame(_ t: Double, _ p: Double) {
            frames.append(LabFrame(t: t, fingers: 1, maxCapacitance: 0.88 + 0.01 * sin(t),
                                   maxPressure: p, maxDensity: 0.5))
        }
        func steady(_ start: Double, _ end: Double, base: Double, peak: Double, at peakTimes: [Double]) {
            var t = start
            while t < end {
                frame(t, peakTimes.contains { abs($0 - t) < 0.08 } ? peak : base)
                t += 0.008
            }
        }
        let times: (Double) -> [Double] = { start in (0..<count).map { start + 1 + Double($0) * 1.6 } }

        steady(0, 6, base: rest, peak: rest, at: [])
        for t0 in times(6) {                       // 轻点：0.1s 接触段，段间无帧
            var t = t0
            while t < t0 + 0.1 { frame(t, abs(t - t0 - 0.05) < 0.02 ? tap : rest); t += 0.008 }
            clicks.append(LabClick(t: t0 + 0.05, button: 0))
        }
        steady(14, 20, base: push, peak: push, at: [])
        steady(20, 30, base: rest, peak: click, at: times(20))
        clicks += times(20).map { LabClick(t: $0, button: 0) }
        steady(30, 42, base: rest, peak: force, at: times(30))
        return LabRecording(protocolID: LabProtocol.pressure.id, recordedAt: Date(),
                            phases: [.init(stepID: "rest", start: 0, end: 6),
                                     .init(stepID: "tap", start: 6, end: 14),
                                     .init(stepID: "push", start: 14, end: 20),
                                     .init(stepID: "click", start: 20, end: 30),
                                     .init(stepID: "force", start: 30, end: 42)],
                            frames: frames, keys: [], clicks: clicks)
    }

    @Test func testPressureSeparableSignalPasses() {
        let r = LabEvaluation.pressure(pressureRecording(rest: 20, tap: 55, push: 120, click: 220, force: 420))
        #expect(r.verdict.passed, Comment(rawValue: r.verdict.lines.joined(separator: "\n")))
        #expect(abs((r.pressure.rest) - (20)) <= 0.001)
        #expect(abs((r.pressure.tap) - (55)) <= 0.001)
        #expect(abs((r.pressure.click) - (220)) <= 0.001)
        #expect(abs((r.pressure.force) - (420)) <= 0.001)
        #expect(!(r.capacitance.isSeparable()), "饱和的 zTotal 不可分")
    }

    /// 深按不产生点击事件，重按次数必须从压力本身数出来。
    @Test func testForcePressesCountedFromPressureNotClicks() {
        let rec = pressureRecording(rest: 20, tap: 55, push: 120, click: 220, force: 420)
        #expect(rec.clicks(in: "force").isEmpty)
        let s = LabEvaluation.spans(rec)
        #expect(s.taps.count == 5)
        #expect(s.clicks.count == 5)
        #expect(s.forces.count == 5)
    }

    /// 重按阶段里力度只到普通点击水平的按压，不算重按。
    @Test func testOrdinaryClickInForcePhaseIsNotAForcePress() {
        let s = LabEvaluation.spans(pressureRecording(rest: 20, tap: 55, push: 120, click: 220, force: 230))
        #expect(s.forces.count == 0)
    }

    @Test func testPressureConstantFieldFails() {
        let r = LabEvaluation.pressure(pressureRecording(rest: 0, tap: 0, push: 0, click: 0, force: 0))
        #expect(!(r.verdict.passed))
        #expect(!(r.pressure.varies))
    }

    @Test func testTapTooCloseToClickFails() {
        let r = LabEvaluation.pressure(pressureRecording(rest: 20, tap: 190, push: 120, click: 220, force: 420))
        #expect(!(r.pressure.tapSeparable()))
        #expect(r.pressure.forceSeparable())
        #expect(!(r.verdict.passed))
    }

    @Test func testPressureNeedsEnoughOfEachKind() {
        let r = LabEvaluation.pressure(pressureRecording(rest: 20, tap: 55, push: 120, click: 220, force: 420,
                                                         count: 2))
        #expect(!(r.verdict.passed))
    }

    @Test func testBoundaryIsGeometricMean() {
        #expect(abs((LabEvaluation.boundary(50, 200)) - (100)) <= 0.001)
    }

    // MARK: - 真机 fixture 回归（2026-10-26 首轮，旧协议：无 tap 阶段）

    private func loadFixture(_ name: String) throws -> LabRecording {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name)")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(LabRecording.self, from: Data(contentsOf: url))
    }

    /// 那次重按阶段实为一次 3.5s 的持续重压（峰值 456）+ 两次短促尖峰，
    /// 只产生 2 个点击事件——旧评估按点击计数因此失效。
    @Test func testRealFixtureForcePressesFromPressure() throws {
        let rec = try loadFixture("mt-pressure-protocol-v1-20261026.json")
        let s = LabEvaluation.spans(rec)
        #expect(s.forces.count == 3)
        let peaks = LabEvaluation.peaks(rec.frames(in: "force"), s.forces) { $0.maxPressure }
        #expect(abs((peaks.max() ?? 0) - (456)) <= 0.5)
    }

    /// 那次「加压」阶段里实际是 13 次轻点（轻点开关开启）：
    /// pressure 轻点峰值远低于物理点击；zTotal 两者几乎相同。
    @Test func testRealFixtureTapsSeparateFromClicksOnlyByPressure() throws {
        let rec = try loadFixture("mt-pressure-protocol-v1-20261026.json")
        let tapSpans = LabEvaluation.contactSpans(rec.frames(in: "push"))
        #expect(tapSpans.count == 13)
        let clickSpans = LabEvaluation.clickSpans(rec.clicks(in: "click"))
        func median(_ spans: [LabEvaluation.Span], _ phase: String, _ v: (LabFrame) -> Double) -> Double {
            LabEvaluation.percentile(50, of: LabEvaluation.peaks(rec.frames(in: phase), spans, v))
        }
        let tapP = median(tapSpans, "push") { $0.maxPressure }
        let clickP = median(clickSpans, "click") { $0.maxPressure }
        let tapZ = median(tapSpans, "push") { $0.maxCapacitance }
        let clickZ = median(clickSpans, "click") { $0.maxCapacitance }
        #expect(clickP / tapP > 3, "pressure：点击约为轻点的 4 倍")
        #expect(clickZ / tapZ < 1.3, "zTotal：点击与轻点几乎无差")
    }

    // MARK: - Lab 按钮点击剔除

    @Test func testUIClickIsDroppedAndPhaseTruncated() {
        let lab = SignalLab()
        lab.setActive(true)
        lab.beginRecording(.pressure, at: 0)
        lab.enterPhase("click", at: 0)
        lab.noteMouseDown(button: 0, at: 2)       // 测试中的点击
        lab.noteMouseDown(button: 0, at: 9.8)     // 点「下一步」
        lab.enterPhase("force", at: 10, byUIClick: true)
        lab.noteMouseDown(button: 0, at: 12)      // 计时自然结束：不剔除
        let rec = lab.endRecording(at: 20)
        #expect(rec?.clicks.map(\.t) == [2, 12])
        #expect(abs((rec?.phase("click")?.end ?? 0) - (9.65)) <= 0.001)
        #expect(rec?.phase("force")?.end == 20)
    }

    @Test func testPressureNoFrames() {
        let rec = LabRecording(protocolID: LabProtocol.pressure.id, recordedAt: Date(),
                               phases: [], frames: [], keys: [], clicks: [])
        #expect(!(LabEvaluation.pressure(rec).verdict.passed))
    }

    // MARK: - 录制器

    private func sample(capacitance: Double, pressure: Double) -> LabContactReadout {
        LabContactReadout(touchID: 1, capacitance: capacitance, pressure: pressure, pressureRawBits: 0,
                          density: 0, majorAxis: 10, minorAxis: 9)
    }

    @Test func testInactiveLabIgnoresInput() {
        let lab = SignalLab()
        lab.noteKeyDown(keyID: "A", isRepeat: false, at: 1)
        lab.noteTouchFrame([sample(capacitance: 1, pressure: 1)], at: 1)
        let s = lab.snapshot(now: 1)
        #expect(s.keyTotals.presses == 0)
        #expect(s.recentFrames.isEmpty)
    }

    @Test func testRecordingTagsPhases() {
        let lab = SignalLab()
        lab.setActive(true)
        lab.beginRecording(.pressure, at: 0)
        lab.enterPhase("rest", at: 0)
        lab.noteTouchFrame([sample(capacitance: 0.9, pressure: 10)], at: 1)
        lab.enterPhase("click", at: 2)
        lab.noteMouseDown(button: 0, at: 3)
        lab.noteTouchFrame([sample(capacitance: 0.9, pressure: 300)], at: 3.05)
        lab.noteKeyDown(keyID: "Delete", isRepeat: true, at: 3.1)
        let rec = lab.endRecording(at: 4)
        #expect(rec?.phases.map(\.stepID) == ["rest", "click"])
        #expect(rec?.frames(in: "rest").map(\.maxPressure) == [10])
        #expect(rec?.clicks(in: "click").count == 1)
        #expect(rec?.keys.first?.isRepeat == true)
        #expect(!(lab.snapshot(now: 4).isRecording))
    }

    @Test func testEmptyFrameClearsContactsButKeepsTrace() {
        let lab = SignalLab()
        lab.setActive(true)
        lab.noteTouchFrame([sample(capacitance: 0.9, pressure: 50)], at: 10)
        lab.noteTouchFrame([], at: 10.01)
        let s = lab.snapshot(now: 10.02)
        #expect(s.contacts.isEmpty, "空帧 = 手指已离开")
        #expect(s.recentFrames.count == 1, "空帧不进曲线")
    }

    @Test func testFrameRateEstimate() {
        let lab = SignalLab()
        lab.setActive(true)
        for i in 0..<125 {
            lab.noteTouchFrame([sample(capacitance: 0.9, pressure: 1)], at: 100 + Double(i) * 0.008)
        }
        let rate = lab.snapshot(now: 101).frameRateHz
        #expect(rate != nil)
        #expect(abs((rate ?? 0) - (125)) <= 1)
    }

    @Test func testFixtureRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lab-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let rec = pressureRecording(rest: 1, tap: 2, push: 2, click: 3, force: 4, count: 1)
        let url = try SignalLab.saveFixture(rec, to: dir)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let back = try decoder.decode(LabRecording.self, from: Data(contentsOf: url))
        #expect(back.frames.count == rec.frames.count)
        #expect(back.phases == rec.phases)
    }
}
