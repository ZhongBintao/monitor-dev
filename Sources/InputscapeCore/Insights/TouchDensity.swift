import Foundation

/// 触控板热力面：24×16 网格 → 放大 ×8 并做可分离高斯平滑 → 对数归一化到 0…1。
/// 纯计算（不涉及颜色），视图层把结果映射成色阶图像。
public enum TouchDensity {

    public static let upsample = 8
    /// 高斯 σ（单位：网格）
    public static let sigmaCells = 1.3

    public struct Field: Equatable, Sendable {
        public let width: Int
        public let height: Int
        /// 行优先，0…1
        public let values: [Double]

        public func value(x: Int, y: Int) -> Double { values[y * width + x] }
    }

    public static func field(grid: [Double], columns: Int = TouchGrid.columns,
                             rows: Int = TouchGrid.rows) -> Field {
        let w = columns * upsample
        let h = rows * upsample
        guard grid.count == columns * rows, (grid.max() ?? 0) > 0 else {
            return Field(width: w, height: h, values: Array(repeating: 0, count: w * h))
        }
        // 1) 最近邻放大：每格均匀铺到 8×8 像素
        var image = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                image[y * w + x] = grid[(y / upsample) * columns + (x / upsample)]
            }
        }
        // 2) 可分离高斯（边缘钳位）
        let sigma = sigmaCells * Double(upsample)
        let radius = Int(ceil(sigma * 3))
        let kernel: [Double] = {
            let raw = (-radius...radius).map { exp(-Double($0 * $0) / (2 * sigma * sigma)) }
            let total = raw.reduce(0, +)
            return raw.map { $0 / total }
        }()
        var temp = [Double](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for k in -radius...radius {
                    let xx = min(w - 1, max(0, x + k))
                    acc += image[y * w + xx] * kernel[k + radius]
                }
                temp[y * w + x] = acc
            }
        }
        for y in 0..<h {
            for x in 0..<w {
                var acc = 0.0
                for k in -radius...radius {
                    let yy = min(h - 1, max(0, y + k))
                    acc += temp[yy * w + x] * kernel[k + radius]
                }
                image[y * w + x] = acc
            }
        }
        // 3) 对数归一化
        let peak = image.max() ?? 0
        guard peak > 0 else { return Field(width: w, height: h, values: image) }
        // 先按峰值归一化再取对数（k 越大，低频区越显眼），与数据单位无关
        let k = 40.0
        let values = image.map { log1p(k * $0 / peak) / log1p(k) }
        return Field(width: w, height: h, values: values)
    }

    /// 3×3 区域名（用于悬停说明）。
    public static func regionName(x: Double, y: Double) -> String {
        let col = min(2, max(0, Int(x * 3)))
        let row = min(2, max(0, Int(y * 3)))
        let names = [["左上", "中上", "右上"], ["左侧", "中央", "右侧"], ["左下", "中下", "右下"]]
        return names[row][col]
    }

    /// 某网格所在 3×3 区域占全部的比例。
    public static func regionShare(grid: [Double], x: Double, y: Double,
                                   columns: Int = TouchGrid.columns, rows: Int = TouchGrid.rows) -> Double {
        let total = grid.reduce(0, +)
        guard total > 0 else { return 0 }
        let col = min(2, max(0, Int(x * 3)))
        let row = min(2, max(0, Int(y * 3)))
        var sum = 0.0
        for r in 0..<rows {
            for c in 0..<columns {
                let rc = min(2, c * 3 / columns)
                let rr = min(2, r * 3 / rows)
                if rc == col && rr == row { sum += grid[r * columns + c] }
            }
        }
        return sum / total
    }
}
