import Foundation

/// 对数热力分档：5 档等比（ln 空间等分）。
/// 少数高频键（空格、删除）不再把其余键压成一片浅色。
public enum HeatScale {

    public static let levels = 5

    /// 0 = 无数据；1…5 = 由浅到深。
    public static func level(_ count: Double, max maxCount: Double) -> Int {
        guard count > 0, maxCount > 0 else { return 0 }
        guard maxCount > 1 else { return levels }
        let ratio = log1p(count) / log1p(maxCount)
        return 1 + min(levels - 1, max(0, Int(floor(ratio * Double(levels)))))
    }

    /// 各档下界（第 1 档恒为 1），取两位有效数字，用于图例。
    public static func boundaries(max maxCount: Double) -> [Double] {
        guard maxCount > 0 else { return [] }
        var out: [Double] = [1]
        for l in 2...levels {
            let raw = pow(1 + maxCount, Double(l - 1) / Double(levels)) - 1
            out.append(Swift.max(1, significant(ceil(raw), digits: 2)))
        }
        // 取整后保持严格递增
        for i in 1..<out.count where out[i] <= out[i - 1] { out[i] = out[i - 1] + 1 }
        return out
    }

    public static func significant(_ value: Double, digits: Int) -> Double {
        guard value >= 10 else { return value.rounded() }
        let scale = pow(10, floor(log10(value)) + 1 - Double(digits))
        return (value / scale).rounded() * scale
    }

    /// 取最接近的 1 / 2 / 5 × 10ⁿ。
    public static func niceRound(_ value: Double) -> Double {
        guard value > 1 else { return 1 }
        let exponent = floor(log10(value))
        let base = pow(10, exponent)
        let fraction = value / base
        let nice: Double
        if fraction < 1.5 { nice = 1 } else if fraction < 3.5 { nice = 2 } else if fraction < 7.5 { nice = 5 } else { nice = 10 }
        return nice * base
    }
}
