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

    var body: some View {
        GeometryReader { geo in
            let need = Self.units * minUnit
            let width = max(geo.size.width, need)
            let height = width * CGFloat(KeyboardLayoutSpec.rowCount) / Self.units
            let content = canvas(unit: width / Self.units)
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
                    .offset(x: CGFloat(key.x) * unit + gap / 2,
                            y: (CGFloat(key.row) + CGFloat(key.yOffset)) * unit + gap / 2)
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

        let shape = RoundedRectangle(cornerRadius: unit * 0.16, style: .continuous)

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

    @ViewBuilder
    private func keycapContent(for key: KeyDefinition, unit: CGFloat, color: Color) -> some View {
        let fontSize = unit * 0.30

        if let icon = key.icon {
            // 图标键：功能行 / 修饰键 / 方向键 / Touch ID
            if let caption = key.caption, unit >= 24 {
                VStack(spacing: unit * 0.04) {
                    iconView(icon, size: unit * 0.30, color: color)
                    Text(caption)
                        .font(.system(size: unit * 0.17, weight: .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
                .foregroundColor(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorAlignment(key.anchor))
            } else if let caption = key.caption, unit < 24 {
                // 缩略模式：仅文字
                Text(caption)
                    .font(.system(size: unit * 0.17, weight: .medium))
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .foregroundColor(color)
                    .frame(maxWidth: .infinity, alignment: anchorAlignment(key.anchor))
            } else {
                iconView(icon, size: unit * 0.34, color: color)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } else if let top = key.topSymbol, let base = key.baseLabel {
            // 双层标注：上方符号、下方数字/字符（US ANSI 对应关系）
            VStack(alignment: .leading, spacing: 0) {
                Text(top).font(.system(size: unit * 0.22, weight: .medium))
                Spacer(minLength: 0)
                Text(base).font(.system(size: fontSize, weight: .regular))
            }
            .foregroundColor(color)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorAlignment(key.anchor))
        } else if let base = key.baseLabel {
            Text(base)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundColor(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorAlignment(key.anchor))
        } else if let caption = key.caption {
            Text(caption)
                .font(.system(size: unit * 0.19, weight: .medium))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .foregroundColor(color)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: anchorAlignment(key.anchor))
        }
    }

    @ViewBuilder
    private func iconView(_ icon: KeycapIcon, size: CGFloat, color: Color) -> some View {
        if let name = Self.sfSymbol(for: icon) {
            Image(systemName: name)
                .font(.system(size: size, weight: .medium))
                .foregroundColor(color)
        }
    }

    private func anchorAlignment(_ anchor: KeycapAnchor, vertical: VerticalAlignment = .center) -> Alignment {
        let horizontal: HorizontalAlignment
        switch anchor {
        case .leading: horizontal = .leading
        case .center: horizontal = .center
        case .trailing: horizontal = .trailing
        }
        return Alignment(horizontal: horizontal, vertical: vertical)
    }

    private func accessibilityName(for key: KeyDefinition) -> String {
        if let caption = key.caption { return caption }
        if let base = key.baseLabel { return base }
        if let top = key.topSymbol { return "键位 \(top)" }
        return key.id
    }

    private static func sfSymbol(for icon: KeycapIcon) -> String? {
        switch icon {
        case .sunLow: return "sun.min"
        case .sunMax: return "sun.max"
        case .missionControl: return "rectangle.split.2x2"
        case .spotlight: return "magnifyingglass"
        case .dictation: return "mic"
        case .doNotDisturb: return "moon.fill"
        case .rewind: return "backward.fill"
        case .playPause: return "playpause.fill"
        case .fastForward: return "forward.fill"
        case .mute: return "speaker.slash.fill"
        case .volumeDown: return "speaker.wave.1.fill"
        case .volumeUp: return "speaker.wave.3.fill"
        case .touchID: return "touchid"
        case .globe: return "globe"
        case .control: return "control"
        case .option: return "option"
        case .command: return "command"
        case .shift: return "shift"
        case .capsLock: return "capslock"
        case .deleteLeft: return "delete.left"
        case .arrowUp: return "arrowtriangle.up.fill"
        case .arrowDown: return "arrowtriangle.down.fill"
        case .arrowLeft: return "arrowtriangle.left.fill"
        case .arrowRight: return "arrowtriangle.right.fill"
        }
    }
}
