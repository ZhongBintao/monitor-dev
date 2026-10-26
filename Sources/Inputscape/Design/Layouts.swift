import SwiftUI

/// 固定宽高比的盒子：按提议宽度给出高度。
/// 竖向 ScrollView 只提议宽度（高度未指定），`.aspectRatio` + GeometryReader 在这种情况下会退回很小的理想尺寸。
struct AspectBox: Layout {
    /// 宽 / 高
    var ratio: CGFloat
    var fallbackWidth: CGFloat = 480

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        var width = proposal.width ?? fallbackWidth
        if !width.isFinite { width = fallbackWidth }
        if proposal.width == nil, let h = proposal.height, h.isFinite { width = h * ratio }
        return CGSize(width: width, height: width / ratio)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
        }
    }
}

/// 宽时左右并排（按比例分宽），窄时上下排列。按实际提议宽度切换，不依赖理想尺寸。
struct AdaptiveRow: Layout {
    var breakpoint: CGFloat = 1000
    /// 并排时第一个子视图占的宽度比例
    var leadingFraction: CGFloat = 0.6
    var spacing: CGFloat = 16

    private func columnWidths(_ width: CGFloat, count: Int) -> [CGFloat] {
        guard count == 2 else { return Array(repeating: width, count: count) }
        let usable = width - spacing
        return [usable * leadingFraction, usable * (1 - leadingFraction)]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil } ?? 1200
        if width >= breakpoint && subviews.count == 2 {
            let widths = columnWidths(width, count: 2)
            let heights = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if bounds.width >= breakpoint && subviews.count == 2 {
            let widths = columnWidths(bounds.width, count: 2)
            var x = bounds.minX
            for (subview, w) in zip(subviews, widths) {
                subview.place(at: CGPoint(x: x, y: bounds.minY), proposal: ProposedViewSize(width: w, height: nil))
                x += w + spacing
            }
        } else {
            var y = bounds.minY
            for subview in subviews {
                let h = subview.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                subview.place(at: CGPoint(x: bounds.minX, y: y), proposal: ProposedViewSize(width: bounds.width, height: h))
                y += h + spacing
            }
        }
    }
}
