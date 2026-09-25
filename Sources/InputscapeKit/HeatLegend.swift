import Foundation

/// 热力图线性分档（渲染与图例的唯一事实源）。
/// 边界 b_k = ceil(maxCount × k / steps)，k = 0…steps；
/// 桶（0-based）i 覆盖计数区间 (b_i, b_{i+1}]，i = 0…steps-1，
/// 与色阶数组（steps 个元素）下标一一对应。
/// 任何热力面着色都必须走同一函数，图例数字才能与格子颜色一一对应。
///
/// 历史：首版返回 1-based 档位导致 `scale[7]` 越界崩溃（最热格必触发，
/// 启动即崩）；2026-09-25 改 0-based 并移入 Kit 补单测。
public enum HeatLegend {

    /// 分档边界（长度 steps+1）：b[0]=0 … b[steps]=maxCount。
    /// maxCount ≤ 0 时返回全 0（调用方此时不应着色）。
    public static func boundaries(maxCount: Int, steps: Int) -> [Int] {
        guard maxCount > 0, steps > 0 else { return Array(repeating: 0, count: steps + 1) }
        return (0...steps).map { Int(ceil(Double(maxCount) * Double($0) / Double(steps))) }
    }

    /// 计数 → 色阶下标（0-based，恒在 0…boundaries.count-2 内）。
    /// count ≤ 0 回落最浅档（着色调用方通常对零计数另有淡底处理）。
    public static func bucketIndex(count: Int, boundaries: [Int]) -> Int {
        let steps = boundaries.count - 1
        guard count > 0, steps > 0 else { return 0 }
        // 桶 i 覆盖 (b[i], b[i+1]]；线性查找即可（steps ≤ 9）。
        for i in 0..<steps where count <= boundaries[i + 1] {
            return i
        }
        return steps - 1
    }

    /// 色阶下标 → 图例数字标签：单值 / 区间 / 末档 max+（不用「低频/高频」文案）。
    public static func label(forStep step: Int, boundaries: [Int]) -> String {
        let steps = boundaries.count - 1
        guard step >= 0, step < steps else { return "" }
        let lower = boundaries[step] + 1
        let upper = boundaries[step + 1]
        if step == steps - 1 { return "\(upper)+" }
        if lower >= upper { return "\(upper)" }
        return "\(lower)–\(upper)"
    }
}
