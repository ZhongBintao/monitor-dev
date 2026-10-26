import Testing
@testable import InputscapeCore

struct RhythmTests {
    let range = 0..<(24 * 60)

    private func active(_ spans: [Range<Int>]) -> [Int: Double] {
        var out: [Int: Double] = [:]
        for s in spans { for m in s { out[m] = 40 } }
        return out
    }

    private func recording(_ r: Range<Int>) -> [Int: CoverageState] {
        Dictionary(uniqueKeysWithValues: r.map { ($0, .recording) })
    }

    @Test func fourMinutePauseKeepsStretch() {
        let s = Rhythm.summarize(range: range, activeSeconds: active([100..<130, 134..<160]),
                                 coverage: recording(range))
        #expect(s.stretches.count == 1)
        #expect(s.longest?.length == 60)
        #expect(s.breaks.isEmpty)
    }

    @Test func fiveMinuteGapIsBreak() {
        let s = Rhythm.summarize(range: range, activeSeconds: active([100..<130, 135..<160]),
                                 coverage: recording(range))
        #expect(s.stretches.count == 2)
        #expect(s.breaks == [Rhythm.Span(start: 130, end: 135)])
        #expect(s.longest?.length == 30)
    }

    @Test func sleepEndsStretch() {
        var cov = recording(range)
        cov[130] = .asleep
        let s = Rhythm.summarize(range: range, activeSeconds: active([100..<130, 131..<160]), coverage: cov)
        #expect(s.stretches.count == 2)
    }

    @Test func unknownMarksIncomplete() {
        var cov = recording(0..<130)
        for m in 160..<range.upperBound { cov[m] = .recording }
        let s = Rhythm.summarize(range: range, activeSeconds: active([100..<130, 140..<160]), coverage: cov)
        #expect(s.stretches.count == 2)
        #expect(s.stretches[0].incomplete)
        #expect(s.stretches[1].incomplete)
        #expect(s.unknown.contains(Rhythm.Span(start: 130, end: 140)))
    }

    @Test func belowThresholdIsNotActive() {
        let s = Rhythm.summarize(range: range, activeSeconds: [100: 5, 101: 9], coverage: recording(range))
        #expect(s.activeMinutes == 0)
        #expect(s.stretches.isEmpty)
    }

    @Test func lateNightAndLongStretches() {
        // 逻辑日从 04:00 起：偏移 19 小时 = 23:00
        let late = Rhythm.lateNightOffsetMinutes
        let s = Rhythm.summarize(range: range, activeSeconds: active([60..<140, late..<(late + 30)]),
                                 coverage: recording(range))
        #expect(s.lateNightMinutes == 30)
        #expect(s.longStretches.count == 1)
        #expect(s.focusBlocks.count == 2)
        #expect(s.lastActiveMinute == late + 29)
    }

    @Test func currentStretchOnlyWhenRecent() {
        let cov = recording(range)
        let s = Rhythm.summarize(range: range, activeSeconds: active([100..<130]), coverage: cov, now: 132)
        #expect(s.current?.length == 30)
        let later = Rhythm.summarize(range: range, activeSeconds: active([100..<130]), coverage: cov, now: 140)
        #expect(later.current == nil)
        // 现在之后的分钟不算未知
        #expect(later.unknown.isEmpty)
    }
}
