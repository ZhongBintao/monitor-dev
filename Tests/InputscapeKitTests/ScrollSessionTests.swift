import XCTest
@testable import InputscapeKit

/// 滚动会话化与手势不应期（去抖核心逻辑，纯函数可测）。
/// 口径：一次物理滑动 = 1 次计数；惯性尾巴并入会话；
/// 微动噪声丢弃；同类手势事件不应期内只计第一次。
final class ScrollSessionTests: XCTestCase {

    // MARK: - 滚动会话化

    /// 一次滑动的事件流（间隔 16ms）→ 会话结束计 1 次，方向主导。
    func testSingleSwipeSessionCountsOnce() {
        var acc = ScrollSessionAccumulator()
        var t: TimeInterval = 100
        // 手指下移（自然滚动：内容下移，delta > 0），30 个事件。
        for _ in 0..<30 {
            XCTAssertNil(acc.accept(delta: 2, at: t), "会话中途不得结算")
            t += 0.016
        }
        // 静默超过间隔后新事件到来 → 先结算上一会话。
        t += 0.5
        let emitted = acc.accept(delta: 1, at: t)
        XCTAssertEqual(emitted, 1, "整段滑动应结算为 1 次下滚")
        XCTAssertNil(acc.flush(), "新事件不应残留旧会话")
    }

    /// 无后续事件时由 flush 兜底结算（静默超时路径）。
    func testFlushClosesIdleSession() {
        var acc = ScrollSessionAccumulator()
        _ = acc.accept(delta: 2, at: 100)
        _ = acc.accept(delta: 2, at: 100.1)
        XCTAssertTrue(acc.hasActiveSession)
        XCTAssertEqual(acc.flush(), 1, "兜底结算应产出方向")
        XCTAssertFalse(acc.hasActiveSession)
        XCTAssertNil(acc.flush(), "空会话 flush 返回 nil")
    }

    /// 上滚（delta < 0）主导的会话结算为 -1。
    func testUpwardSwipeDominantDirection() {
        var acc = ScrollSessionAccumulator()
        var t: TimeInterval = 0
        for _ in 0..<20 {
            _ = acc.accept(delta: -1.5, at: t)
            t += 0.01
        }
        XCTAssertEqual(acc.flush(), -1, "负 delta 主导 → 上滚")
    }

    /// 会话内中途反向：按 |delta| 主导方向结算。
    func testDominantDirectionWinsOverTail() {
        var acc = ScrollSessionAccumulator()
        var t: TimeInterval = 0
        for _ in 0..<10 { _ = acc.accept(delta: 2, at: t); t += 0.01 }   // 下移 20
        for _ in 0..<3 { _ = acc.accept(delta: -2, at: t); t += 0.01 }  // 上移 6
        XCTAssertEqual(acc.flush(), 1, "下移 20 > 上移 6 → 下滚")
    }

    /// 微动噪声：总位移低于门限的会话（轻触微动事件串）不计数。
    func testMicroJitterSessionDiscarded() {
        var acc = ScrollSessionAccumulator(minimumDisplacement: 3.0)
        var t: TimeInterval = 0
        for _ in 0..<2 {
            _ = acc.accept(delta: 1, at: t)
            t += 0.01
        }
        XCTAssertNil(acc.flush(), "位移 2 < 门限 3 应丢弃")
    }

    /// 惯性 momentum 事件（间隔 < 会话间隔）自然并入会话尾，不新开会话。
    func testMomentumTailJoinsSession() {
        var acc = ScrollSessionAccumulator()
        var t: TimeInterval = 0
        for _ in 0..<10 { _ = acc.accept(delta: 2, at: t); t += 0.02 }   // 手指阶段
        for _ in 0..<40 { _ = acc.accept(delta: 0.5, at: t); t += 0.016 } // 惯性阶段
        XCTAssertNil(acc.accept(delta: 1, at: t + 0.1), "惯性后 100ms 仍属同一会话")
        XCTAssertEqual(acc.flush(), 1, "整段（含惯性）= 1 次下滚")
    }

    /// 间隔超阈值才开新会话：两次独立滑动各计 1 次。
    func testTwoSeparateSwipesCountTwice() {
        var acc = ScrollSessionAccumulator()
        var t: TimeInterval = 0
        for _ in 0..<10 { _ = acc.accept(delta: 2, at: t); t += 0.016 }
        t += 0.6 // 明确超过会话间隔
        XCTAssertEqual(acc.accept(delta: -2, at: t), 1, "第一次滑动结算为下滚")
        for _ in 0..<8 { _ = acc.accept(delta: -2, at: t); t += 0.016 }
        XCTAssertEqual(acc.flush(), -1, "第二次滑动结算为上滚")
    }

    // MARK: - 手势不应期

    /// 不应期窗口内的同类事件只接受第一次。
    func testRefractoryGateSuppressesDuplicates() {
        var gate = GestureRefractoryGate(interval: 0.3)
        XCTAssertTrue(gate.shouldAccept(at: 10.0))
        XCTAssertFalse(gate.shouldAccept(at: 10.1), "100ms 后重复投递应被吸收")
        XCTAssertFalse(gate.shouldAccept(at: 10.29))
        XCTAssertTrue(gate.shouldAccept(at: 10.31), "超过不应期后重新接受")
    }

    /// reset 后立即重新接受（停/启监听场景）。
    func testRefractoryGateReset() {
        var gate = GestureRefractoryGate(interval: 0.3)
        XCTAssertTrue(gate.shouldAccept(at: 10.0))
        gate.reset()
        XCTAssertTrue(gate.shouldAccept(at: 10.05), "reset 后不应期失效")
    }
}
