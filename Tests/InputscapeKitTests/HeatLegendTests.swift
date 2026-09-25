import XCTest
@testable import InputscapeKit

/// 热力图线性分档（渲染与图例的唯一事实源）。
/// 回归守护：bucketIndex 必须恒落在 0…steps-1——首版返回 1-based 档位
/// 导致最热格 scale[7] 越界、应用启动即崩（EXC_BREAKPOINT）。
final class HeatLegendTests: XCTestCase {

    private let steps = 7

    private func makeBoundaries(max: Int) -> [Int] {
        HeatLegend.boundaries(maxCount: max, steps: steps)
    }

    /// 边界单调不减、首 0 末 max、长度 steps+1。
    func testBoundariesShapeAndMonotonicity() {
        for max in [1, 5, 7, 100, 12_480] {
            let b = makeBoundaries(max: max)
            XCTAssertEqual(b.count, steps + 1)
            XCTAssertEqual(b[0], 0)
            XCTAssertEqual(b[steps], max)
            for i in 1..<b.count {
                XCTAssertGreaterThanOrEqual(b[i], b[i - 1], "边界必须单调不减 (max=\(max))")
            }
        }
        XCTAssertEqual(HeatLegend.boundaries(maxCount: 0, steps: 7),
                       Array(repeating: 0, count: 8), "max=0 返回全 0 边界（调用方不应着色）")
    }

    /// **越界回归**：任意 count（含超过上界的防御值）下标都不得 ≥ steps。
    func testBucketIndexAlwaysWithinScaleRange() {
        let b = makeBoundaries(max: 150)
        for count in -5...200 {
            let index = HeatLegend.bucketIndex(count: count, boundaries: b)
            XCTAssertGreaterThanOrEqual(index, 0)
            XCTAssertLessThan(index, steps,
                              "count=\(count) 的下标 \(index) 越出色阶（0…\(steps - 1)）")
        }
    }

    /// 映射语义：最浅计数 → 0，跨边界递进，最热计数（=max）→ 末档 steps-1。
    func testBucketIndexMapping() {
        let b = makeBoundaries(max: 150)
        XCTAssertEqual(b[1], 22, "ceil(150/7)=22")
        XCTAssertEqual(HeatLegend.bucketIndex(count: 1, boundaries: b), 0)
        XCTAssertEqual(HeatLegend.bucketIndex(count: 22, boundaries: b), 0, "b1 上界含")
        XCTAssertEqual(HeatLegend.bucketIndex(count: 23, boundaries: b), 1)
        XCTAssertEqual(HeatLegend.bucketIndex(count: 150, boundaries: b), steps - 1, "max 落末档")
        XCTAssertEqual(HeatLegend.bucketIndex(count: 999, boundaries: b), steps - 1, "防御：超界钳末档")
        XCTAssertEqual(HeatLegend.bucketIndex(count: 0, boundaries: b), 0)
        // 全零边界（max≤0 的防御形态）：count 超出所有边界 → 钳末档，不越界。
        XCTAssertEqual(HeatLegend.bucketIndex(count: 5, boundaries: Array(repeating: 0, count: 8)),
                       steps - 1, "超出所有边界钳末档，恒在 0…steps-1 内")
    }

    /// 图例标签：首档单值/区间、末档 max+、退化区间显示单值。
    func testStepLabels() {
        let b = makeBoundaries(max: 150)
        // b = [0, 22, 43, 65, 86, 108, 129, 150]
        XCTAssertEqual(HeatLegend.label(forStep: 0, boundaries: b), "1–22")
        XCTAssertEqual(HeatLegend.label(forStep: 1, boundaries: b), "23–43")
        XCTAssertEqual(HeatLegend.label(forStep: steps - 1, boundaries: b), "150+")
        XCTAssertEqual(HeatLegend.label(forStep: -1, boundaries: b), "")
        XCTAssertEqual(HeatLegend.label(forStep: steps, boundaries: b), "")

        // 退化场景 max < steps：区间塌成单值也不越界。
        let tiny = makeBoundaries(max: 3)
        for step in 0..<steps {
            XCTAssertFalse(HeatLegend.label(forStep: step, boundaries: tiny).isEmpty)
        }
        XCTAssertEqual(HeatLegend.label(forStep: steps - 1, boundaries: tiny), "3+")
    }
}
