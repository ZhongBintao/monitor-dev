import Testing
import Foundation
@testable import InputscapeCore

/// Phase 0 · P1（时间戳单位）与 P8（输入源分类）的纯函数部分。
/// P8 真机 ID 录得后（Lab「输入源 · 保存」）追加为回归用例。
struct ProbeTests {

    // MARK: - P1 时间戳单位

    @Test func testTimestampUnitNanoseconds() {
        #expect(LabEvaluation.timestampUnit(unitsPerSecond: 1.02e9, machTicksPerSecond: 24e6) == .nanoseconds)
    }

    @Test func testTimestampUnitMachTicks() {
        #expect(LabEvaluation.timestampUnit(unitsPerSecond: 23.9e6, machTicksPerSecond: 24e6) == .machTicks)
    }

    @Test func testTimestampUnitPrefersNanosecondsWhenTicksAreNanoseconds() {
        // Intel：mach tick 即纳秒
        #expect(LabEvaluation.timestampUnit(unitsPerSecond: 1e9, machTicksPerSecond: 1e9) == .nanoseconds)
    }

    @Test func testTimestampUnitUnknown() {
        #expect(LabEvaluation.timestampUnit(unitsPerSecond: 5e8, machTicksPerSecond: 24e6) == .unknown)
    }

    @Test func testProbeNeedsOneSecondSpan() {
        var probe = LabTimestampProbe(firstRaw: 1_000, firstUptime: 10, lastRaw: 1_000 + 12_000_000,
                                      lastUptime: 10.5, samples: 5)
        #expect(probe.unitsPerSecond == nil)
        probe.lastRaw = 1_000 + 48_000_000
        probe.lastUptime = 12
        #expect(abs((probe.unitsPerSecond ?? 0) - (24e6)) <= 1)
    }

    @Test func testLabCollectsTimestampsOnlyWhileActive() {
        let lab = SignalLab()
        lab.noteEventTimestamp(raw: 100, at: 1)
        #expect(lab.snapshot(now: 1).timestampProbe == nil)
        lab.setActive(true)
        lab.noteEventTimestamp(raw: 100, at: 1)
        lab.noteEventTimestamp(raw: 100 + 2_000_000_000, at: 3)
        #expect(abs((lab.snapshot(now: 3).timestampProbe?.unitsPerSecond ?? 0) - (1e9)) <= 1)
        lab.setActive(false)
        #expect(lab.snapshot(now: 3).timestampProbe == nil)
    }

    // MARK: - P8 输入源分类

    private func kind(_ id: String, layout: Bool = false, _ languages: [String] = []) -> InputSourceKind {
        InputSourceInfo(id: id, isKeyboardLayout: layout, languages: languages).kind
    }

    @Test func testKeyboardLayoutsAreLatin() {
        #expect(kind("com.apple.keylayout.ABC", layout: true, ["en"]) == .latin)
        #expect(kind("com.apple.keylayout.US", layout: true, ["en"]) == .latin)
    }

    @Test func testPinyinInputMethods() {
        #expect(kind("com.apple.inputmethod.SCIM.ITABC", ["zh-Hans"]) == .zhPinyin)
        #expect(kind("com.apple.inputmethod.SCIM.Shuangpin", ["zh-Hans"]) == .zhPinyin)
        #expect(kind("com.apple.inputmethod.TCIM.Pinyin", ["zh-Hant"]) == .zhPinyin)
        #expect(kind("com.tencent.inputmethod.wetype.pinyin", ["zh-Hans"]) == .zhPinyin)
        #expect(kind("com.sogou.inputmethod.sogou.pinyin", ["zh-Hans"]) == .zhPinyin)
    }

    @Test func testOtherChineseInputMethods() {
        #expect(kind("com.apple.inputmethod.SCIM.WBX", ["zh-Hans"]) == .zhOther)
        // 语言缺失时按 SCIM/TCIM 前缀识别
        #expect(kind("com.apple.inputmethod.TCIM.Zhuyin") == .zhOther)
    }

    @Test func testJapaneseKoreanAndOther() {
        #expect(kind("com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", ["ja"]) == .ja)
        #expect(kind("com.apple.inputmethod.Korean.2SetKorean", ["ko"]) == .ko)
        #expect(kind("com.apple.CharacterPaletteIM", []) == .other)
    }
}
