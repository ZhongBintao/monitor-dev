import SwiftUI
import AppKit

/// 视觉规范（设计文档 §6）：浅色、克制、数据仪表盘。
/// 深海军蓝主文字、蓝紫色键盘统计、珊瑚红触控板、绿色仅用于运行状态。
///
/// 夜览（深色）模式：所有语义色均为**动态颜色**——底层是
/// `NSColor(name:dynamicProvider:)`，SwiftUI 在窗口 effectiveAppearance
/// 变化时自动重新求值并重绘。因此设置页切换三档显示模式（改动
/// `NSApp.appearance`）或系统深浅色切换时，全部页面即时同步，无需重启。
/// 浅色值与设计稿一致；深色值为同语义的夜览配对色（主文字反转为近白，
/// 强调色整体提亮一档以保证对暗底的对比度）。
public enum Theme {

    // MARK: - 动态颜色基础设施

    /// 构造动态颜色：解析外观为深色时取 dark 组，否则取 light 组。
    /// 用 `bestMatch` 判定深浅（对高对比度增强等派生外观同样成立）。
    private static func dynamicColor(
        _ light: (CGFloat, CGFloat, CGFloat),
        _ dark: (CGFloat, CGFloat, CGFloat),
        lightAlpha: CGFloat = 1,
        darkAlpha: CGFloat = 1
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b,
                           alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    // MARK: - 基础

    /// 页面底色。浅 #F5F7F9 / 深 #16181D
    public static let background = dynamicColor((0.962, 0.969, 0.976), (0.086, 0.094, 0.114))
    /// 卡片底色。浅 white / 深 #21242A
    public static let card = dynamicColor((1, 1, 1), (0.129, 0.141, 0.165))
    /// 键帽底色（浅色与卡片同为白；深色比卡片亮一档，呈「凸起」感）
    public static let keycap = dynamicColor((1, 1, 1), (0.161, 0.176, 0.208))
    /// 分隔线 / 描边。浅 #E7EAEF / 深 #393E4A
    public static let hairline = dynamicColor((0.906, 0.918, 0.937), (0.224, 0.243, 0.290))

    // MARK: - 文字

    /// 主文字：深海军蓝 / 夜览近白（#E8EBF2）
    public static let navy = dynamicColor((0.106, 0.169, 0.290), (0.910, 0.922, 0.949))
    public static let secondary = dynamicColor((0.541, 0.576, 0.651), (0.639, 0.671, 0.737))
    public static let tertiary = dynamicColor((0.678, 0.706, 0.761), (0.427, 0.459, 0.529))

    // MARK: - 语义色

    /// 蓝紫：键盘。夜览提亮一档保证对暗底的对比度
    public static let keyPurple = dynamicColor((0.357, 0.404, 0.878), (0.510, 0.553, 0.949))
    /// 蓝紫软底（选中态胶囊 / 行高亮）：夜览加深透明度
    public static let keyPurpleSoft = dynamicColor(
        (0.357, 0.404, 0.878), (0.510, 0.553, 0.949),
        lightAlpha: 0.12, darkAlpha: 0.22)
    /// 珊瑚红：触控板
    public static let coral = dynamicColor((0.941, 0.396, 0.361), (0.973, 0.502, 0.455))
    public static let coralSoft = dynamicColor(
        (0.941, 0.396, 0.361), (0.973, 0.502, 0.455),
        lightAlpha: 0.12, darkAlpha: 0.22)
    /// 绿：仅运行状态
    public static let statusGreen = dynamicColor((0.188, 0.690, 0.357), (0.220, 0.804, 0.408))

    /// 键盘热力 5 档色阶（低频 → 高频）。夜览为暗底同梯度蓝紫：
    /// 低档贴近键帽底色（弱数据安静），高档到提亮主色。
    public static let heatScale: [Color] = [
        dynamicColor((0.933, 0.941, 0.980), (0.161, 0.176, 0.208)),
        dynamicColor((0.827, 0.843, 0.973), (0.208, 0.227, 0.349)),
        dynamicColor((0.682, 0.706, 0.949), (0.286, 0.318, 0.569)),
        dynamicColor((0.510, 0.553, 0.910), (0.380, 0.427, 0.780)),
        dynamicColor((0.357, 0.404, 0.878), (0.510, 0.553, 0.949))
    ]

    /// 触控板色阶（低频 → 高频，珊瑚红）。
    public static let coralScale: [Color] = [
        dynamicColor((0.988, 0.925, 0.918), (0.180, 0.161, 0.169)),
        dynamicColor((0.980, 0.839, 0.824), (0.294, 0.204, 0.220)),
        dynamicColor((0.973, 0.706, 0.686), (0.443, 0.271, 0.290)),
        dynamicColor((0.957, 0.545, 0.510), (0.643, 0.318, 0.333)),
        dynamicColor((0.941, 0.396, 0.361), (0.973, 0.502, 0.455))
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

    /// 热力格上的文字颜色：深色格子用白字，浅色格子用主文字色
    /// （主文字为动态色——夜览下自动换成近白，两档格子都清晰可读）。
    public static func heatTextColor(_ intensity: Double) -> Color {
        intensity >= 0.5 ? .white : navy
    }
}
