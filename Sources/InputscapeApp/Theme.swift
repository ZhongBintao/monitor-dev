import SwiftUI

/// 视觉规范（设计文档 §6）：浅色、克制、数据仪表盘。
/// 深海军蓝主文字、蓝紫色键盘统计、珊瑚红触控板、绿色仅用于运行状态。
public enum Theme {

    // 基础
    public static let background = Color(red: 0.962, green: 0.969, blue: 0.976)   // #F5F7F9
    public static let card = Color.white
    public static let hairline = Color(red: 0.906, green: 0.918, blue: 0.937)

    // 文字
    public static let navy = Color(red: 0.106, green: 0.169, blue: 0.290)         // 深海军蓝
    public static let secondary = Color(red: 0.541, green: 0.576, blue: 0.651)
    public static let tertiary = Color(red: 0.678, green: 0.706, blue: 0.761)

    // 语义色
    public static let keyPurple = Color(red: 0.357, green: 0.404, blue: 0.878)    // 蓝紫：键盘
    public static let keyPurpleSoft = Color(red: 0.357, green: 0.404, blue: 0.878, opacity: 0.12)
    public static let coral = Color(red: 0.941, green: 0.396, blue: 0.361)        // 珊瑚红：触控板
    public static let coralSoft = Color(red: 0.941, green: 0.396, blue: 0.361, opacity: 0.12)
    public static let statusGreen = Color(red: 0.188, green: 0.690, blue: 0.357)  // 绿：仅运行状态

    /// 键盘热力 5 档色阶（低频 → 高频）。
    public static let heatScale: [Color] = [
        Color(red: 0.933, green: 0.941, blue: 0.980),
        Color(red: 0.827, green: 0.843, blue: 0.973),
        Color(red: 0.682, green: 0.706, blue: 0.949),
        Color(red: 0.510, green: 0.553, blue: 0.910),
        Color(red: 0.357, green: 0.404, blue: 0.878)
    ]

    /// 触控板色阶（低频 → 高频，珊瑚红）。
    public static let coralScale: [Color] = [
        Color(red: 0.988, green: 0.925, blue: 0.918),
        Color(red: 0.980, green: 0.839, blue: 0.824),
        Color(red: 0.973, green: 0.706, blue: 0.686),
        Color(red: 0.957, green: 0.545, blue: 0.510),
        Color(red: 0.941, green: 0.396, blue: 0.361)
    ]

    /// 把 0...1 的强度映射到色阶；0 强度回落到第一档（有淡底，保证可见）。
    public static func heatColor(_ intensity: Double, scale: [Color] = heatScale) -> Color {
        guard !scale.isEmpty else { return .gray }
        guard intensity > 0 else { return scale.first ?? .gray }
        let clamped = min(max(intensity, 0), 1)
        let scaled = clamped * Double(scale.count - 1)
        let index = min(Int(scaled.rounded(.up)), scale.count - 1)
        return scale[index]
    }

    /// 热力格上的文字颜色：深色格子用白字，浅色格子用深字。
    public static func heatTextColor(_ intensity: Double) -> Color {
        intensity >= 0.5 ? .white : navy
    }
}
