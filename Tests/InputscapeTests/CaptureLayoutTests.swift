import Testing
@testable import InputscapeCapture

/// MTTouch 按 96 字节逐字段读取：布局变了宁可拒绝启动（MultitouchBridge.start 的守护条件）。
struct CaptureLayoutTests {
    @Test func mtTouchLayout() {
        #expect(MemoryLayout<MTTouchC>.stride == 96)
        #expect(MemoryLayout<MTTouchC>.offset(of: \MTTouchC.zTotal) == 48)
        #expect(MemoryLayout<MTTouchC>.offset(of: \MTTouchC.pressure) == 52)
        #expect(MemoryLayout<MTTouchC>.offset(of: \MTTouchC.zDensity) == 92)
    }

    @Test func deviceModifierBitsAreDistinct() {
        let bits = Array(EventTap.deviceModifierBits.values)
        #expect(Set(bits).count == bits.count)
    }
}
