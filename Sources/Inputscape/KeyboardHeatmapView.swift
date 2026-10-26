import SwiftUI
import InputscapeCore

/// 唯一键盘渲染视图：几何与键帽字形全部来自 KeyboardLayoutSpec（78 键 US ANSI）。
/// Today 热力图与实时页共用；除尺寸、热力颜色与高亮外，不允许任何键位 / 图标 / 标签差异。
struct KeyboardHeatmapView: View {

    var values: [String: Int] = [:]
    /// 当前物理按住的键（实时页：按下缩放高亮、松开回弹）
    var pressedKeys: Set<String> = []
    /// 被外部强调的键（Top 列表悬停时）
    var emphasizedKeyID: String? = nil
    /// 悬停提示文字；返回 nil 不显示
    var tooltip: ((String) -> String?)? = nil
    var onHoverKey: ((String?) -> Void)? = nil
    var reduceMotion = false

    @State private var hoveredKeyID: String?

    /// 键区四周外边距（u）
    private static let outerMargin: CGFloat = 0.1
    private static let totalUnits = CGFloat(KeyboardLayoutSpec.rowUnits) + outerMargin * 2
    private static let totalRows = CGFloat(KeyboardLayoutSpec.rowCount) + outerMargin * 2
    /// 画布纵横比（含外边距），由规范推导
    static let canvasAspectRatio: CGFloat = totalUnits / totalRows

    /// 键帽在画布中的矩形（绘制与悬停提示共用同一套几何）。
    static func keyRect(_ key: KeyDefinition, unit: CGFloat) -> CGRect {
        let gap = unit * 0.10
        return CGRect(x: (CGFloat(key.x) + outerMargin) * unit + gap / 2,
                      y: (CGFloat(key.row) + CGFloat(key.yOffset) + outerMargin) * unit + gap / 2,
                      width: CGFloat(key.width) * unit - gap,
                      height: CGFloat(key.height) * unit - gap)
    }

    var body: some View {
        // 按容器宽度等比缩放，键位比例始终与实物一致
        AspectBox(ratio: Self.canvasAspectRatio, fallbackWidth: 720) {
            GeometryReader { geo in
                let unit = geo.size.width / Self.totalUnits
                canvas(unit: unit)
                    .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            }
        }
    }

    private func canvas(unit: CGFloat) -> some View {
        let maxCount = Double(values.values.max() ?? 0)
        return ZStack(alignment: .topLeading) {
            ForEach(KeyboardLayoutSpec.keys) { key in
                let rect = Self.keyRect(key, unit: unit)
                keycap(for: key, unit: unit, maxCount: maxCount)
                    .frame(width: rect.width, height: rect.height, alignment: .topLeading)
                    .offset(x: rect.minX, y: rect.minY)
            }
            if let id = hoveredKeyID, let key = KeyboardLayoutSpec.key(withID: id),
               let text = tooltip?(id) {
                tooltipBubble(text, over: Self.keyRect(key, unit: unit), canvasWidth: Self.totalUnits * unit)
            }
        }
    }

    private func tooltipBubble(_ text: String, over rect: CGRect, canvasWidth: CGFloat) -> some View {
        let bubbleWidth: CGFloat = 170
        let x = min(max(rect.midX - bubbleWidth / 2, 0), canvasWidth - bubbleWidth)
        let below = rect.minY < 44
        return Text(text)
            .font(.caption.monospacedDigit())
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(width: bubbleWidth)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.regularMaterial))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(Theme.hairline, lineWidth: 0.5))
            .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
            .fixedSize(horizontal: false, vertical: true)
            .alignmentGuide(.top) { d in below ? -(rect.maxY + 6) : -(rect.minY - d.height - 6) }
            .offset(x: x)
            .allowsHitTesting(false)
    }

    @ViewBuilder
    private func keycap(for key: KeyDefinition, unit: CGFloat, maxCount: Double) -> some View {
        let count = values[key.id] ?? 0
        let level = values.isEmpty ? 0 : HeatScale.level(Double(count), max: maxCount)
        let isPressed = pressedKeys.contains(key.id)
        let isFocused = hoveredKeyID == key.id || emphasizedKeyID == key.id

        let fill: Color = isPressed ? Theme.keyboard : Theme.keyboardRamp[level]
        let contentColor: Color = {
            if isPressed { return .white }
            if level > 0 { return Theme.keyboardText(level: level) }
            return key.isObservable ? Theme.primary : Theme.tertiary
        }()

        let shape = RoundedRectangle(cornerRadius: unit * 0.09, style: .continuous)
        ZStack {
            shape.fill(fill)
            shape.stroke(isFocused || isPressed ? Theme.keyboard : Theme.hairline,
                         lineWidth: isFocused ? 2 : (isPressed ? 1.4 : 0.8))
            keycapContent(for: key, unit: unit, color: contentColor)
                .padding(unit * 0.10)
            if key.homeIndicator {
                Capsule()
                    .fill(contentColor.opacity(0.55))
                    .frame(width: unit * 0.14, height: unit * 0.05)
                    .offset(y: unit * 0.36)
            }
            if key.ledIndicator {
                Circle()
                    .fill(contentColor.opacity(0.45))
                    .frame(width: unit * 0.08, height: unit * 0.08)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(.leading, unit * 0.14)
                    .padding(.top, unit * 0.10)
            }
        }
        .scaleEffect(isPressed && !reduceMotion ? 0.92 : 1)
        .animation(reduceMotion ? nil : .linear(duration: 0.05), value: isPressed)
        .contentShape(shape)
        .onHover { inside in
            if inside {
                hoveredKeyID = key.id
                onHoverKey?(key.id)
            } else if hoveredKeyID == key.id {
                hoveredKeyID = nil
                onHoverKey?(nil)
            }
        }
        .accessibilityLabel(Text(accessibilityName(for: key)))
        .accessibilityValue(Text(count > 0 ? "\(count) 次" : "无数据"))
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
        case .touchID:
            // 指纹识别区：居中圆环 + 内圆，大小与键帽比例协调
            ZStack {
                Circle()
                    .stroke(color.opacity(0.55), lineWidth: unit * 0.045)
                Circle()
                    .fill(color.opacity(0.18))
                    .frame(width: unit * 0.32, height: unit * 0.32)
            }
            .frame(width: unit * 0.5, height: unit * 0.5)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .blank:
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
