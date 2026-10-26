import SwiftUI
import InputscapeCore
import InputscapeCapture

/// 实时：按下的键在键盘上点亮，手指在触控板上画出接触椭圆。只在本页可见时以 30 Hz 读取。
struct LiveView: View {
    @Environment(CaptureSupervisor.self) private var capture

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: false)) { context in
            let snap = capture.live.snapshot()
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.xl) {
                    header(snap, now: context.date)
                    Card("键盘") {
                        KeyboardHeatmapView(pressedKeys: snap.pressedKeys)
                    }
                    HStack(alignment: .top, spacing: Spacing.l) {
                        Card("触控板", subtitle: snap.touches.isEmpty ? nil : "\(snap.touches.count) 指") {
                            TouchpadLivePanel(touches: snap.touches)
                        }
                        .frame(maxWidth: 560)
                        Card("当前") {
                            VStack(alignment: .leading, spacing: 10) {
                                row("输入源", capture.inputSource.id.isEmpty ? "—" : sourceLabel)
                                row("触控板", capture.trackpadAvailable ? "内置触控板已连接" : "不可用（只记录键盘）")
                                row("按住的键", snap.pressedKeys.isEmpty ? "—"
                                    : snap.pressedKeys.sorted().map(KeyboardPanel.keyName).joined(separator: " "))
                                if let p = snap.touches.map(\.pressure).max() {
                                    row("按压力度", String(format: "%.0f", p))
                                }
                            }
                        }
                    }
                }
                .padding(Spacing.page)
                .frame(maxWidth: 1480, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("实时")
    }

    private var sourceLabel: String {
        let kind = capture.inputSource.kind
        let name: String
        switch kind {
        case .zhPinyin: name = "中文 · 拼音"
        case .zhOther: name = "中文"
        case .latin: name = "英文"
        case .ja: name = "日文"
        case .ko: name = "韩文"
        case .other: name = "其他"
        }
        return name
    }

    private func header(_ snap: LiveFeed.Snapshot, now: Date) -> some View {
        let idle = snap.lastInput.map { Int(now.timeIntervalSince($0)) }
        return VStack(alignment: .leading, spacing: 4) {
            Text("实时").font(.system(size: 28, weight: .bold))
            Text(capture.status == .recording
                 ? (idle.map { $0 < 2 ? "正在输入" : "空闲 \($0) 秒" } ?? "等待输入")
                 : capture.status.label)
                .font(.subheadline.monospacedDigit()).foregroundStyle(Theme.secondary)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout)
        }
    }
}

/// 接触椭圆：长 / 短轴按毫米换算为面板宽度比例并随角度旋转，透明度随按压力度。
struct TouchpadLivePanel: View {
    let touches: [TouchPoint]

    var body: some View {
        AspectBox(ratio: 1.6) {
        GeometryReader { proxy in
            let size = proxy.size
            let shape = RoundedRectangle(cornerRadius: size.height * 0.07, style: .continuous)
            ZStack {
                shape.fill(Theme.keycap)
                Canvas { context, canvasSize in
                    // 内置触控板宽约 160 mm：1 mm ≈ 宽度的 1/160，椭圆按 1.6 倍放大便于看清
                    let unit = canvasSize.width / 100.0
                    for t in touches {
                        let w = t.majorAxis * unit, h = t.minorAxis * unit
                        let path = Path(ellipseIn: CGRect(x: -w / 2, y: -h / 2, width: w, height: h))
                            .rotation(.radians(-t.angle), anchor: .topLeading)
                            .offset(x: t.x * canvasSize.width, y: t.y * canvasSize.height)
                            .path(in: CGRect(origin: .zero, size: canvasSize))
                        let intensity = 0.3 + 0.6 * min(1, t.pressure / 300)
                        context.fill(path, with: .color(Theme.trackpad.opacity(intensity)))
                    }
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 0.8))
        }
        }
        .accessibilityLabel(touches.isEmpty ? "触控板，无触点" : "触控板，\(touches.count) 个触点")
    }
}
