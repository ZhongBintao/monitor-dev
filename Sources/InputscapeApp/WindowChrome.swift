import SwiftUI
import AppKit

/// 窗口 chrome 修正：无标题栏样式下的窗口拖动性。
///
/// 应用采用 `.windowStyle(.hiddenTitleBar)`：没有系统标题栏与工具栏，
/// 状态栏（品牌行）直接成为窗口第一栏——顶部无空白、无系统材质带，
/// 也不存在工具栏安全区把内容下压的问题。
///
/// 代价是系统不再提供标题栏拖拽区，这里用
/// `isMovableByWindowBackground` 补回：窗口任意非交互区域均可拖动。
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
            window?.isMovableByWindowBackground = true
        }
    }

    func makeNSView(context: Context) -> NSView { FixingView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? FixingView)?.viewDidMoveToWindow()
    }
}
