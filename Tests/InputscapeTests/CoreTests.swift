import Testing
import Foundation
@testable import InputscapeCore

struct KeyClassifierTests {
    @Test func categories() {
        #expect(KeyClassifier.counter(for: "A") == .keyLetter)
        #expect(KeyClassifier.counter(for: "Space") == .keySpace)
        #expect(KeyClassifier.counter(for: "Delete") == .keyDelete)
        #expect(KeyClassifier.counter(for: "Return") == .keyReturn)
        #expect(KeyClassifier.counter(for: "ArrowUp") == .keyNav)
        #expect(KeyClassifier.counter(for: "Escape") == .keyNav)
        #expect(KeyClassifier.counter(for: "ShiftLeft") == .keyModifier)
        #expect(KeyClassifier.counter(for: "CapsLock") == .keyModifier)
        #expect(KeyClassifier.counter(for: "F11") == .keyFunction)
        #expect(KeyClassifier.counter(for: "Digit5") == .keyDigitPunct)
        #expect(KeyClassifier.counter(for: "Comma") == .keyDigitPunct)
        #expect(KeyClassifier.counter(for: "Fn") == .keyModifier)
    }

    @Test func everyLayoutKeyIsClassified() {
        for key in KeyboardLayoutSpec.observableKeys {
            _ = KeyClassifier.counter(for: key.id)
        }
        #expect(KeyClassifier.isCandidateDigit("Digit1"))
        #expect(!KeyClassifier.isCandidateDigit("Digit0"))
    }

    @Test func shortcutsNeedCommandOrControl() {
        #expect(ShortcutRule.comboID(modifiers: [.command], keyID: "C") == "⌘C")
        #expect(ShortcutRule.comboID(modifiers: [.shift, .command], keyID: "Digit3") == "⇧⌘3")
        #expect(ShortcutRule.comboID(modifiers: [.control], keyID: "A") == "⌃A")
        // ⇧ / ⌥ 单独按住是在打字，不是快捷键
        #expect(ShortcutRule.comboID(modifiers: [.shift], keyID: "I") == nil)
        #expect(ShortcutRule.comboID(modifiers: [.option], keyID: "E") == nil)
        // 修饰键本身不构成快捷键
        #expect(ShortcutRule.comboID(modifiers: [.command], keyID: "ShiftLeft") == nil)
    }
}

struct MinuteAccumulatorTests {
    let base = Date(timeIntervalSince1970: 1_800_000_000)  // 整分钟

    @Test func repeatsAreSeparateFromPresses() {
        let acc = MinuteAccumulator()
        acc.recordKey(id: "Delete", isRepeat: false, at: base)
        for i in 1...10 { acc.recordKey(id: "Delete", isRepeat: true, at: base.addingTimeInterval(Double(i) * 0.05)) }
        let batch = acc.drain()
        let row = batch.rows.values.reduce(into: Counters()) { $0.merge($1) }
        #expect(row[.keyDelete] == 1)
        #expect(row[.keyRepeat] == 10)
        #expect(row.keyPresses == 1)
        let tally = batch.keys.values.first
        #expect(tally?.presses == 1)
        #expect(tally?.repeats == 10)
    }

    @Test func activeSecondsSplitAcrossMinutes() {
        let acc = MinuteAccumulator()
        let start = base.addingTimeInterval(50)
        for i in 0...20 { acc.recordKey(id: "A", isRepeat: false, at: start.addingTimeInterval(Double(i))) }
        let batch = acc.drain()
        let m0 = MinuteAccumulator.minute(of: base)
        let active = batch.rows.reduce(into: [Int: Double]()) { $0[$1.key.minute, default: 0] += $1.value[.activeSeconds] }
        #expect(abs((active[m0] ?? 0) - 10) < 0.001)
        #expect(abs((active[m0 + 1] ?? 0) - 10) < 0.001)
    }

    @Test func gapOfSixtySecondsBreaksSegment() {
        let acc = MinuteAccumulator()
        acc.recordKey(id: "A", isRepeat: false, at: base)
        acc.recordKey(id: "A", isRepeat: false, at: base.addingTimeInterval(61))
        let total = acc.drain().rows.values.map { $0[.activeSeconds] }.reduce(0, +)
        #expect(total == 0)
    }

    @Test func disabledDropsEverything() {
        let acc = MinuteAccumulator()
        acc.setEnabled(false)
        acc.recordKey(id: "A", isRepeat: false, at: base)
        acc.recordClick(.press, at: base)
        #expect(acc.drain().isEmpty)
    }

    @Test func rowsAreKeyedByInputSource() {
        let acc = MinuteAccumulator()
        let pinyin = InputSourceInfo(id: "com.apple.inputmethod.SCIM.ITABC", isKeyboardLayout: false, languages: ["zh-Hans"])
        let abc = InputSourceInfo(id: "com.apple.keylayout.ABC", isKeyboardLayout: true, languages: ["en"])
        acc.setInputSource(pinyin)
        acc.recordKey(id: "N", isRepeat: false, at: base)
        acc.setInputSource(abc)
        acc.recordKey(id: "N", isRepeat: false, at: base.addingTimeInterval(1))
        let batch = acc.drain()
        #expect(batch.rows.count == 2)
        #expect(batch.sources.count == 2)
        #expect(batch.sources[pinyin.id]?.kind == .zhPinyin)
    }

    @Test func drainEmptiesTheBatch() {
        let acc = MinuteAccumulator()
        acc.recordScroll(dx: 3, dy: -40, momentum: false, at: base)
        acc.recordScroll(dx: 0, dy: 100, momentum: true, at: base)
        let row = acc.drain().rows.values.first
        #expect(row?[.scrollVerticalPx] == 40)
        #expect(row?[.scrollHorizontalPx] == 3)
        #expect(row?[.scrollMomentumPx] == 100)
        #expect(acc.drain().isEmpty)
    }
}

struct TouchTrackerTests {
    private func frames(_ tracker: TouchTracker, from t0: Double, count: Int, step: Double = 0.008,
                        points: (Int) -> [TouchPoint]) -> [TouchTracker.Output] {
        (0..<count).map { tracker.ingest(time: t0 + Double($0) * step, touches: points($0)) }
    }

    @Test func landingsCountFingersNotFrames() {
        let tracker = TouchTracker()
        let outs = frames(tracker, from: 0, count: 100) { _ in [TouchPoint(id: 1, x: 0.5, y: 0.5)] }
        #expect(outs.flatMap(\.contribution.landings).count == 1)
        let contact = outs.map(\.contribution.contactSeconds).reduce(0, +)
        #expect(abs(contact - 99 * 0.008) < 0.0001)
    }

    @Test func frameGapIsClamped() {
        let tracker = TouchTracker()
        _ = tracker.ingest(time: 0, touches: [TouchPoint(id: 1, x: 0.5, y: 0.5)])
        let out = tracker.ingest(time: 5, touches: [TouchPoint(id: 1, x: 0.5, y: 0.5)])
        #expect(out.contribution.contactSeconds == TouchTracker.maxFrameInterval)
    }

    @Test func restingFingerIsNotMoving() {
        let tracker = TouchTracker()
        let outs = frames(tracker, from: 0, count: 125) { i in
            [TouchPoint(id: 1, x: 0.5 + (i % 2 == 0 ? 0.0001 : -0.0001), y: 0.5)]
        }
        #expect(outs.map(\.contribution.moveSeconds).reduce(0, +) == 0)
    }

    @Test func movingFingerIsActivity() {
        let tracker = TouchTracker()
        let outs = frames(tracker, from: 0, count: 60) { i in [TouchPoint(id: 1, x: 0.2 + Double(i) * 0.005, y: 0.5)] }
        #expect(outs.map(\.contribution.moveSeconds).reduce(0, +) > 0.3)
    }

    @Test func sessionEndsAfterGraceAndIsClassified() {
        let tracker = TouchTracker()
        _ = frames(tracker, from: 0, count: 40) { i in
            [TouchPoint(id: 1, x: 0.3, y: 0.3 + Double(i) * 0.004), TouchPoint(id: 2, x: 0.4, y: 0.3 + Double(i) * 0.004)]
        }
        _ = tracker.ingest(time: 0.4, touches: [])
        #expect(tracker.flush(now: 0.45) == nil)          // 宽限期内
        #expect(tracker.flush(now: 0.6) == .scroll)
        #expect(tracker.flush(now: 0.7) == nil)
    }

    @Test func newContactAfterGraceEndsPreviousSession() {
        let tracker = TouchTracker()
        _ = tracker.ingest(time: 0, touches: [TouchPoint(id: 1, x: 0.5, y: 0.5)])
        _ = tracker.ingest(time: 0.05, touches: [TouchPoint(id: 1, x: 0.5, y: 0.5)])
        _ = tracker.ingest(time: 0.06, touches: [])
        let out = tracker.ingest(time: 1, touches: [TouchPoint(id: 2, x: 0.5, y: 0.5)])
        #expect(out.endedSession == .tap)
    }

    @Test func sessionClassifier() {
        #expect(TouchSessionClassifier.classify(.init(duration: 1, maxFingers: 1, travel: 0.2)) == .point)
        #expect(TouchSessionClassifier.classify(.init(duration: 0.1, maxFingers: 1, travel: 0)) == .tap)
        #expect(TouchSessionClassifier.classify(.init(duration: 3, maxFingers: 1, travel: 0.001)) == .rest)
        #expect(TouchSessionClassifier.classify(.init(duration: 1, maxFingers: 2, travel: 0.1)) == .scroll)
        #expect(TouchSessionClassifier.classify(.init(duration: 1, maxFingers: 2, travel: 0.02, spreadChange: 0.08)) == .pinch)
        #expect(TouchSessionClassifier.classify(.init(duration: 0.4, maxFingers: 3, travel: 0.2)) == .swipe3)
        #expect(TouchSessionClassifier.classify(.init(duration: 0.4, maxFingers: 4, travel: 0.2)) == .swipe4)
    }

    @Test func clickClassifierMatchesPhaseZeroLevels() {
        #expect(ClickClassifier.classify(isRightButton: false, peakPressure: nil) == .other)
        #expect(ClickClassifier.classify(isRightButton: false, peakPressure: 50) == .tap)
        #expect(ClickClassifier.classify(isRightButton: false, peakPressure: 200) == .press)
        #expect(ClickClassifier.classify(isRightButton: false, peakPressure: 450) == .heavy)
        #expect(ClickClassifier.classify(isRightButton: true, peakPressure: 60) == .right)
    }

    @Test func pressureRingPeakNeedsContact() {
        let ring = PressureRing()
        ring.record(t: 10, maxPressure: 0, fingers: 0)
        #expect(ring.peak(from: 9.9, to: 10.3) == nil)
        ring.record(t: 10.1, maxPressure: 180, fingers: 1)
        ring.record(t: 10.2, maxPressure: 240, fingers: 1)
        #expect(ring.peak(from: 9.9, to: 10.3) == 240)
    }
}

struct HeatAndDensityTests {
    @Test func logLevels() {
        #expect(HeatScale.level(0, max: 1000) == 0)
        #expect(HeatScale.level(1, max: 1000) == 1)
        #expect(HeatScale.level(1000, max: 1000) == 5)
        // 对数：中等频率的键不会被空格压成最浅
        #expect(HeatScale.level(100, max: 1000) >= 3)
        #expect(HeatScale.level(5, max: 5) == 5)
    }

    @Test func boundariesIncreaseAndAreNice() {
        let b = HeatScale.boundaries(max: 1200)
        #expect(b.count == 5)
        #expect(b.first == 1)
        #expect(zip(b, b.dropFirst()).allSatisfy { $0 < $1 })
        #expect(HeatScale.niceRound(37) == 50)
        #expect(HeatScale.niceRound(130) == 100)
    }

    @Test func densityIsNormalizedAndSmooth() {
        var grid = [Double](repeating: 0, count: TouchGrid.cellCount)
        grid[TouchGrid.cell(x: 0.5, y: 0.5)] = 100
        let field = TouchDensity.field(grid: grid)
        #expect(field.width == 192 && field.height == 128)
        #expect(abs((field.values.max() ?? 0) - 1) < 1e-9)
        // 平滑后邻近像素也有值，远处为 0
        let peakIndex = field.values.firstIndex(of: field.values.max()!)!
        #expect(field.values[peakIndex + 8] > 0.3)
        #expect(field.value(x: 0, y: 0) < 0.01)
    }

    @Test func emptyGridGivesEmptyField() {
        let field = TouchDensity.field(grid: [Double](repeating: 0, count: TouchGrid.cellCount))
        #expect(field.values.allSatisfy { $0 == 0 })
    }

    @Test func regionShares() {
        var grid = [Double](repeating: 0, count: TouchGrid.cellCount)
        grid[TouchGrid.cell(x: 0.9, y: 0.9)] = 3
        grid[TouchGrid.cell(x: 0.1, y: 0.1)] = 1
        #expect(TouchDensity.regionName(x: 0.9, y: 0.9) == "右下")
        #expect(abs(TouchDensity.regionShare(grid: grid, x: 0.9, y: 0.9) - 0.75) < 1e-9)
    }
}

struct LogicalDayTests {
    @Test func dayStartsAtFourAM() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let threeAM = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 3, minute: 30))!
        let fiveAM = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 5))!
        #expect(LogicalDay(containing: threeAM).id == "2026-10-26")
        #expect(LogicalDay(containing: fiveAM).id == "2026-10-27")
        let day = LogicalDay(id: "2026-10-26")!
        #expect(day.minuteRange.count == 24 * 60)
        #expect(day.adding(days: 1).id == "2026-10-27")
    }

    @Test func rangeDays() {
        let r = DayRange(LogicalDay(id: "2026-10-28")!, LogicalDay(id: "2026-10-26")!)
        #expect(r.start.id == "2026-10-26")
        #expect(r.dayCount == 3)
    }
}

/// 用 Phase 0 真机夹具验证点击分类：轻点来点按的 mouseDown 晚于抬指 16–31 ms，仍在回看窗口内。
struct ClickFixtureTests {
    struct Fixture: Decodable {
        struct Frame: Decodable { let t: Double; let fingers: Int; let maxPressure: Double }
        struct Click: Decodable { let t: Double; let button: Int }
        struct Phase: Decodable { let stepID: String; let start: Double; let end: Double }
        let frames: [Frame]
        let clicks: [Click]
        let phases: [Phase]
    }

    @Test func fixtureClicksClassify() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/mt-pressure-protocol-v1-20261026.json")
        let fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
        let ring = PressureRing()
        var kinds: [String: [ClickKind]] = [:]
        var frameIndex = 0
        for click in fixture.clicks.sorted(by: { $0.t < $1.t }) {
            // 回放到点击之后 0.3 秒
            while frameIndex < fixture.frames.count, fixture.frames[frameIndex].t <= click.t + ClickClassifier.lookAhead {
                let f = fixture.frames[frameIndex]
                ring.record(t: f.t, maxPressure: f.maxPressure, fingers: f.fingers)
                frameIndex += 1
            }
            let peak = ring.peak(from: click.t - ClickClassifier.lookBehind, to: click.t + ClickClassifier.lookAhead)
            let kind = ClickClassifier.classify(isRightButton: click.button == 1, peakPressure: peak)
            let phase = fixture.phases.first { click.t >= $0.start && click.t <= $0.end }?.stepID ?? "?"
            kinds[phase, default: []].append(kind)
        }
        #expect(kinds["push"]?.allSatisfy { $0 == .tap } == true)
        #expect(kinds["click"]?.allSatisfy { $0 == .press } == true)
        #expect((kinds["push"]?.count ?? 0) >= 10)
    }
}
