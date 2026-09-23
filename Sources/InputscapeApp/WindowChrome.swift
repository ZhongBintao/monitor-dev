import SwiftUI
import AppKit

/// 窗口 chrome 修正：标题栏透明化 + 去掉标题栏底部分隔线。
///
/// 背景：应用顶部品牌行（状态栏）自绘在内容区里，而系统标题栏是
/// 另一条不透明材质带（深色模式 ~#1E2024），叠在状态栏上方，形成
/// 两条颜色不一致的横栏——状态栏卡片色（Theme.card）与标题栏材质
/// 色对不上。透明化后，标题栏区域直接露出内容视图已绘制的主题
/// 背景（左侧栏 Theme.background / 右状态栏 Theme.card），上下合并
/// 为一栏，明暗模式都与整体主题一致。
///
/// 标题栏拖拽、红绿灯、侧栏开关全部保留；标题文字隐藏由
/// WindowGroup 上的 `.windowToolbarStyle(.unified(showsTitle: false))`
/// 继续负责，这里再兜底一层 `titleVisibility = .hidden`。
///
/// 以 NSViewRepresentable 挂在根视图：WindowGroup 可开多窗，
/// 每个新窗口的视图层级里都带一份，随视图挂窗自动生效。
struct WindowChromeFixer: NSViewRepresentable {

    final class FixingView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }
        private func apply() {
            guard let window else { return }
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
        }
    }

    func makeNSView(context: Context) -> NSView { FixingView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FixingView)?.viewDidMoveToWindow()
    }
}
