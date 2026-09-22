import SwiftUI
import InputscapeKit

/// 唯一键盘渲染视图：从 KeyboardLayoutSpec 派生，供总览缩略键盘、
/// 键盘分布热力图、实时观察键盘三处复用。
/// 除尺寸、数据颜色与高亮状态外，不允许存在键位 / 图标 / 标签差异。
struct KeyboardHeatmapView: View {

    var values: [String: Int] = [:]
    var highlightKeyID: String? = nil
    /// 当前物理按住的键位集合（实时跟手：按下缩放高亮、松开回弹）。
    var pressedKeys: Set<String> = []
    @Binding var selectedKeyID: String?
    var reduceMotion = false
    /// 最小键距（pt）：窗口过窄时保持物理比例并允许横向滚动。
    var minUnit: CGFloat = 30
    /// 窄容器时是否允许横向滚动（离屏渲染 / 快照测试时关闭，
    /// 因为 ImageRenderer 不渲染 ScrollView 内容）。
    var scrollWhenNarrow = true

    init(values: [String: Int] = [:],
         highlightKeyID: String? = nil,
         pressedKeys: Set<String> = [],
         selectedKeyID: Binding<String?> = .constant(nil),
         reduceMotion: Bool = false,
         minUnit: CGFloat = 30,
         scrollWhenNarrow: Bool = true) {
        self.values = values
        self.highlightKeyID = highlightKeyID
        self.pressedKeys = pressedKeys
        self._selectedKeyID = selectedKeyID
        self.reduceMotion = reduceMotion
        self.minUnit = minUnit
        self.scrollWhenNarrow = scrollWhenNarrow
    }

    private static let units: CGFloat = CGFloat(KeyboardLayoutSpec.rowUnits)
    /// 键盘四周外边距（u）：避免键区贴边被裁的观感（用户反馈方向键"向下突出"
    /// 实为贴边 + 裁切的视觉误差）。
    private static let outerMargin: CGFloat = 0.1
    private static let totalUnits: CGFloat = CGFloat(KeyboardLayoutSpec.rowUnits) + 0.2
    private static let totalRows: CGFloat = CGFloat(KeyboardLayoutSpec.rowCount) + 0.2
    /// 画布纵横比（含外边距），供调用方 aspectRatio 使用
    static let canvasAspectRatio: CGFloat = 14.7 / 6.2

    var body: some View {
        GeometryReader { geo in
            let need = Self.totalUnits * minUnit
            let width = max(geo.size.width, need)
            let unit = width / Self.totalUnits
            let height = Self.totalRows * unit
            let content = canvas(unit: unit)
                // 关键：ZStack 自然尺寸只有最大子键大小（offset 不参与布局），
                // 必须显式 topLeading 对齐，否则整个键区会被居中放置而错位。
                .frame(width: width, height: height, alignment: .topLeading)
            if scrollWhenNarrow {
                ScrollView(.horizontal, showsIndicators: false) { content }
            } else {
                content
            }
        }
    }

    private func canvas(unit: CGFloat) -> some View {
        let gap = unit * 0.10
        let maxCount = max(values.values.max() ?? 0, 1)

        return ZStack(alignment: .topLeading) {
            ForEach(KeyboardLayoutSpec.keys) { key in
                keycap(for: key, unit: unit, gap: gap, maxCount: maxCount)
                    .frame(width: CGFloat(key.width) * unit - gap,
                           height: CGFloat(key.height) * unit - gap,
                           alignment: .topLeading)
                    .offset(x: (CGFloat(key.x) + Self.outerMargin) * unit + gap / 2,
                            y: (CGFloat(key.row) + CGFloat(key.yOffset) + Self.outerMargin) * unit + gap / 2)
            }
        }
    }

    @ViewBuilder
    private func keycap(for key: KeyDefinition, unit: CGFloat, gap: CGFloat, maxCount: Int) -> some View {
        let count = values[key.id] ?? 0
        let intensity = count > 0 ? Double(count) / Double(maxCount) : 0
        let isHighlighted = highlightKeyID == key.id
        let isPressed = pressedKeys.contains(key.id)
        let isSelected = selectedKeyID == key.id
        let heatOn = !values.isEmpty

        let fill: Color = {
            if isPressed { return Theme.keyPurple }
            if isHighlighted { return Theme.keyPurple.opacity(0.75) }
            if heatOn && count > 0 { return Theme.heatColor(intensity) }
            return Color.white
        }()
        let contentColor: Color = (isPressed || isHighlighted)
            ? .white
            : (heatOn && count > 0 ? Theme.heatTextColor(intensity) : (key.isObservable ? Theme.navy : Theme.secondary))

        if key.style == .touchID {
            // Touch ID：裸圆环（参考图样式，无键帽边框），不可观察无热力
            ZStack {
                Circle()
                    .stroke(isPressed ? Theme.keyPurple : Theme.hairline,
                            lineWidth: isPressed ? 1.6 : 1)
                Circle()
                    .fill(isPressed ? Theme.keyPurple.opacity(0.4) : Theme.keyPurpleSoft.opacity(0.8))
                    .frame(width: unit * 0.42, height: unit * 0.42)
            }
            .onTapGesture { selectedKeyID = key.id }
            .accessibilityLabel(Text("Touch ID"))
            .accessibilityHint(Text("不产生可观察事件"))
        } else {
            let shape = RoundedRectangle(cornerRadius: unit * 0.09, style: .continuous)
            Group {
                ZStack {
                    shape.fill(fill)
                    shape.stroke(isSelected || isPressed ? Theme.keyPurple : Theme.hairline,
                                 lineWidth: isSelected ? 2.2 : (isPressed ? 1.4 : 1))
                    keycapContent(for: key, unit: unit, color: contentColor)
                        .padding(unit * 0.10)
                    if key.homeIndicator {
                        Capsule()
                            .fill(contentColor.opacity(0.55))
                            .frame(width: unit * 0.14, height: unit * 0.05)
                            .offset(y: unit * 0.36)
                    }
                    if key.ledIndicator {
                        // caps lock LED 指示点（参考图：键帽左上角小圆点）
                        Circle()
                            .fill(contentColor.opacity(0.45))
                            .frame(width: unit * 0.08, height: unit * 0.08)
                            .frame(maxWidth: .infinity, maxHeight: .infinity,
                                   alignment: .topLeading)
                            .padding(.leading, unit * 0.14)
                            .padding(.top, unit * 0.10)
                    }
                }
            }
            // 跟手反馈：按下瞬间点亮缩放、松开立即消失；减少动效时禁用。
            .scaleEffect(isPressed && !reduceMotion ? 0.90 : 1)
            .animation(reduceMotion ? nil : .linear(duration: 0.04), value: isPressed)
            .animation(reduceMotion ? nil : .linear(duration: 0.08), value: highlightKeyID)
            .onTapGesture { selectedKeyID = key.id }
            .accessibilityLabel(Text(accessibilityName(for: key)))
            .accessibilityValue(Text(count > 0 ? "\(count) 次" : "无数据"))
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        }
    }

    // MARK: - 键帽内容（按 KeycapStyle 逐样式渲染）

    @ViewBuilder
    private func keycapContent(for key: KeyDefinition, unit: CGFloat, color: Color) -> some View {
        switch key.style {
        case .twin:
            // 双层标注：上符号 / 下字符，居中（参考图样式）
            if let top = key.topSymbol, let base = key.baseLabel {
                VStack(spacing: 0) {
                    Text(top).font(.system(size: unit * 0.21, weight: .medium))
                    Spacer(minLength: 0)
                    Text(base).font(.system(size: unit * 0.28, weight: .regular))
                }
                .foregroundColor(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .letter:
            if let base = key.baseLabel {
                Text(base)
                    .font(.system(size: unit * 0.30, weight: .medium))
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .fKey:
            VStack(spacing: unit * 0.04) {
                if let glyph = key.glyph {
                    glyphView(glyph, size: unit * 0.28, color: color)
                }
                if let word = key.word {
                    Text(word)
                        .font(.system(size: unit * 0.165, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .iconWordTrailing:
            // 图标上、单词下，右对齐（右侧 command / option）
            VStack(alignment: .trailing, spacing: 0) {
                if let glyph = key.glyph {
                    glyphView(glyph, size: unit * 0.26, color: color)
                }
                Spacer(minLength: 0)
                if let word = key.word {
                    Text(word)
                        .font(.system(size: unit * 0.15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.trailing, unit * 0.13)
            .padding(.vertical, unit * 0.10)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
        case .iconWordCorners:
            // 图标左下、单词右下，底部对齐（fn）
            // 注意：keycap() 已有 0.10u 外层 padding，内层边距必须极小，
            // 且单词禁止换行（否则 1u 键帽内 "fn" 会被拆成上下两层）
            HStack(alignment: .bottom, spacing: unit * 0.05) {
                if let glyph = key.glyph {
                    glyphView(glyph, size: unit * 0.20, color: color)
                }
                if let word = key.word {
                    Text(word)
                        .font(.system(size: unit * 0.15, weight: .medium))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, unit * 0.03)
            .padding(.bottom, unit * 0.10) // 与 iconWordLeading 的词底同高（对齐 control 字母）
            .foregroundColor(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        case .iconWordLeading:
            // 图标上、单词下，左对齐（fn / control / option / command）
            VStack(alignment: .leading, spacing: 0) {
                if let glyph = key.glyph {
                    glyphView(glyph, size: unit * 0.26, color: color)
                }
                Spacer(minLength: 0)
                if let word = key.word {
                    Text(word)
                        .font(.system(size: unit * 0.15, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(.leading, unit * 0.13)
            .padding(.vertical, unit * 0.10)
            .foregroundColor(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        case .iconCentered:
            // 半高方向键：字形随半高缩小
            if let glyph = key.glyph {
                glyphView(glyph, size: unit * (key.height < 1 ? 0.24 : 0.32), color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        case .iconLeadingMiddle:
            if let glyph = key.glyph {
                glyphView(glyph, size: unit * 0.26, color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                    .padding(.leading, unit * 0.18)
            }
        case .iconTrailingMiddle:
            if let glyph = key.glyph {
                glyphView(glyph, size: unit * 0.26, color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, unit * 0.18)
            }
        case .iconCornerLeading:
            if let glyph = key.glyph {
                glyphView(glyph, size: unit * 0.26, color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, unit * 0.14)
                    .padding(.bottom, unit * 0.10)
            }
        case .iconCornerTrailing:
            if let glyph = key.glyph {
                glyphView(glyph, size: unit * 0.26, color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomTrailing)
                    .padding(.trailing, unit * 0.14)
                    .padding(.bottom, unit * 0.10)
            }
        case .wordLeading:
            if let word = key.word {
                Text(word)
                    .font(.system(size: unit * 0.19, weight: .medium))
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity,
                           alignment: .bottomLeading)
                    .padding(.leading, unit * 0.14)
                    .padding(.bottom, unit * 0.10)
            }
        case .touchID, .blank:
            EmptyView()
        }
    }

    @ViewBuilder
    private func glyphView(_ glyph: KeyGlyph, size: CGFloat, color: Color) -> some View {
        switch glyph {
        case .unicode(let character):
            Text(character)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(color)
        case .sfSymbol(let name):
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(color)
        }
    }

    private func accessibilityName(for key: KeyDefinition) -> String {
        if let word = key.word { return word }
        if let base = key.baseLabel { return base }
        if let top = key.topSymbol { return "键位 \(top)" }
        return key.id
    }
}
