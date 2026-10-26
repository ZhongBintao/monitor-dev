import SwiftUI
import AppKit

/// 视觉 token（方向 A · 原生 Mac 精修）：系统字体与语义色、自动深浅色；
/// 热力沿用 v1 的蓝紫（键盘）与珊瑚红（触控板），5 档对数色阶。
/// 所有颜色都是动态色：外观切换时 SwiftUI 自动重算。
enum Theme {

    private static func dynamic(_ light: (CGFloat, CGFloat, CGFloat),
                                _ dark: (CGFloat, CGFloat, CGFloat),
                                lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (r, g, b) = isDark ? dark : light
            return NSColor(srgbRed: r, green: g, blue: b, alpha: isDark ? darkAlpha : lightAlpha)
        })
    }

    // MARK: 表面

    static let window = Color(nsColor: .windowBackgroundColor)
    /// 卡片：浅色为白，深色比窗口亮一档
    static let card = dynamic((1, 1, 1), (0.155, 0.160, 0.175))
    /// 键帽底色（深色比卡片再亮一档，呈「凸起」感）
    static let keycap = dynamic((0.985, 0.987, 0.992), (0.205, 0.212, 0.232))
    static let hairline = Color(nsColor: .separatorColor)

    // MARK: 文字

    static let primary = Color(nsColor: .labelColor)
    static let secondary = Color(nsColor: .secondaryLabelColor)
    static let tertiary = Color(nsColor: .tertiaryLabelColor)

    // MARK: 语义色

    /// 蓝紫：键盘
    static let keyboard = dynamic((0.357, 0.404, 0.878), (0.545, 0.585, 0.965))
    /// 珊瑚红：触控板
    static let trackpad = dynamic((0.925, 0.380, 0.345), (0.973, 0.502, 0.455))
    static let ok = Color(nsColor: .systemGreen)
    static let warn = Color(nsColor: .systemOrange)
    /// 休息 / 空闲
    static let rest = Color(nsColor: .quaternaryLabelColor)

    /// 5 档键盘热力（第 0 档 = 无数据，用键帽色）
    static let keyboardRamp: [Color] = [
        keycap,
        dynamic((0.902, 0.914, 0.988), (0.215, 0.232, 0.330)),
        dynamic((0.792, 0.812, 0.973), (0.270, 0.296, 0.470)),
        dynamic((0.643, 0.671, 0.945), (0.345, 0.380, 0.640)),
        dynamic((0.494, 0.537, 0.914), (0.430, 0.470, 0.820)),
        dynamic((0.357, 0.404, 0.878), (0.545, 0.585, 0.965)),
    ]

    /// 5 档触控板热力（第 0 档 = 透明）
    static let trackpadRampRGB: [(light: (Double, Double, Double), dark: (Double, Double, Double))] = [
        ((0.996, 0.957, 0.949), (0.200, 0.170, 0.175)),
        ((0.988, 0.878, 0.859), (0.300, 0.205, 0.210)),
        ((0.973, 0.757, 0.722), (0.450, 0.265, 0.265)),
        ((0.957, 0.600, 0.553), (0.650, 0.340, 0.330)),
        ((0.925, 0.380, 0.345), (0.973, 0.502, 0.455)),
    ]

    static var trackpadRamp: [Color] {
        trackpadRampRGB.map { dynamic(($0.light.0, $0.light.1, $0.light.2), ($0.dark.0, $0.dark.1, $0.dark.2)) }
    }

    /// 热力格上的文字：深档用浅字。与填充同一档位决定，避免 v1 的填充 / 文字不一致。
    static func keyboardText(level: Int) -> Color {
        level >= 4 ? Color.white : primary
    }
}

enum Spacing {
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let page: CGFloat = 28
}

enum Radius {
    static let card: CGFloat = 12
    static let small: CGFloat = 6
}

// MARK: - 通用容器

/// 卡片：标题 + 可选尾部控件 + 内容。
struct Card<Trailing: View, Content: View>: View {
    var title: String?
    var subtitle: String?
    @ViewBuilder var trailing: () -> Trailing
    @ViewBuilder var content: () -> Content

    init(_ title: String? = nil, subtitle: String? = nil,
         @ViewBuilder trailing: @escaping () -> Trailing = { EmptyView() },
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.m) {
            if title != nil || Trailing.self != EmptyView.self {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.s) {
                    if let title {
                        Text(title).font(.headline)
                    }
                    if let subtitle {
                        Text(subtitle).font(.subheadline).foregroundStyle(Theme.secondary)
                    }
                    Spacer(minLength: Spacing.s)
                    trailing()
                }
            }
            content()
        }
        .padding(Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }
}

/// 色阶图例：少 ▢▢▢▢▢ 多，附各档下界数字。
struct HeatLegend: View {
    let colors: [Color]
    let boundaries: [Double]
    var unit: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Text("少").font(.caption2).foregroundStyle(Theme.secondary)
            ForEach(Array(colors.enumerated()), id: \.offset) { i, color in
                VStack(spacing: 2) {
                    RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 22, height: 8)
                        .overlay(RoundedRectangle(cornerRadius: 2).stroke(Theme.hairline.opacity(0.5), lineWidth: 0.5))
                    if i < boundaries.count {
                        Text(Format.compact(boundaries[i]) + (i == colors.count - 1 ? "+" : ""))
                            .font(.system(size: 9).monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                }
            }
            Text("多" + (unit.isEmpty ? "" : "（\(unit)）")).font(.caption2).foregroundStyle(Theme.secondary)
        }
    }
}

// MARK: - 格式

enum Format {
    static func compact(_ value: Double) -> String {
        if value >= 10_000 { return String(format: "%.0fk", value / 1000) }
        if value >= 1_000 { return String(format: "%.1fk", value / 1000) }
        return String(Int(value.rounded()))
    }

    static func number(_ value: Int) -> String { value.formatted() }

    /// 时长：5 小时 12 分 / 38 分钟
    static func duration(seconds: Double) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(minutes) 分钟" }
        let h = minutes / 60, m = minutes % 60
        return m == 0 ? "\(h) 小时" : "\(h) 小时 \(m) 分"
    }

    /// 紧凑时长：5h12 / 38m
    static func shortDuration(minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        return String(format: "%dh%02d", minutes / 60, minutes % 60)
    }

    static func distance(pixels: Double) -> String {
        // 屏幕点 → 米：按约 110 点 / 英寸估算（Retina 逻辑点）
        let meters = pixels / 110 * 0.0254
        if meters >= 1000 { return String(format: "%.1f km", meters / 1000) }
        if meters >= 1 { return String(format: "%.0f m", meters) }
        return String(format: "%.0f cm", meters * 100)
    }

    static func clock(minute: Int) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: Date(timeIntervalSince1970: Double(minute) * 60))
    }

    static func dayTitle(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M 月 d 日 EEEE"
        return f.string(from: date)
    }

    static func shortDay(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "M/d"
        return f.string(from: date)
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
