import AppKit
import SwiftUI

/// AppKit 原生 Tooltip 桥接：NSView.toolTip 由系统管理
/// 悬停检测、显示延迟、定位、贴边与消失，行为与全 Mac
/// 应用的原生提示完全一致——零自研状态机，杜绝
/// 自定义悬停跟踪的各类边界缺陷。
///
/// 用作小图标（如 ⓘ）的背景层，为其提供足够的悬停热区。
struct AppKitTooltip: NSViewRepresentable {
    let text: String

    final class TooltipHostView: NSView {
        var tooltipText: String = "" {
            didSet {
                if tooltipText != toolTip {
                    toolTip = tooltipText
                }
            }
        }
    }

    func makeNSView(context: Context) -> TooltipHostView {
        let view = TooltipHostView()
        view.toolTip = text
        return view
    }

    func updateNSView(_ view: TooltipHostView, context: Context) {
        view.tooltipText = text
    }
}
