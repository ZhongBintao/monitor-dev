import SwiftUI
import InputscapeCore

/// 触控板热力面（高斯平滑）+ 落点 / 接触时长切换 + 点击构成 + 手势构成。
struct TrackpadPanel: View {
    let report: DayReport

    enum Metric: String, CaseIterable { case landings, contact }

    @State private var metric: Metric = .landings
    @State private var hover: CGPoint?

    var body: some View {
        // 旧版日只有接触时长，没有落点
        let hasLandings = report.landings.contains { $0 > 0 }
        let effective: Metric = hasLandings ? metric : .contact
        let grid = effective == .landings ? report.landings : report.contactSecondsGrid

        Card("触控板") {
            if hasLandings {
                Picker("指标", selection: $metric) {
                    Text("落点").tag(Metric.landings)
                    Text("接触时长").tag(Metric.contact)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .help("落点 = 手指每次落下的位置；接触时长 = 手指停留的时间")
            }
        } content: {
            VStack(alignment: .leading, spacing: Spacing.m) {
                TrackpadSurface(grid: grid, hover: $hover)
                hoverLine(grid: grid, metric: effective)
                clicks
                gestures
            }
        }
    }

    @ViewBuilder
    private func hoverLine(grid: [Double], metric: Metric) -> some View {
        let total = grid.reduce(0, +)
        if let p = hover, total > 0 {
            let share = TouchDensity.regionShare(grid: grid, x: p.x, y: p.y)
            Text("\(TouchDensity.regionName(x: p.x, y: p.y)) · 占\(metric == .landings ? "落点" : "接触时长") \(Format.percent(share))")
                .font(.caption).foregroundStyle(Theme.secondary)
        } else if total > 0 {
            Text(metric == .landings ? "共 \(Format.number(Int(total))) 次落指 · 悬停查看区域占比"
                                     : "共 \(Format.duration(seconds: total)) 手指接触 · 悬停查看区域占比")
                .font(.caption).foregroundStyle(Theme.tertiary)
        } else {
            Text("还没有触控数据").font(.caption).foregroundStyle(Theme.tertiary)
        }
    }

    private var clicks: some View {
        let t = report.totals
        let rows: [RankRow] = [
            RankRow(id: "press", label: "按下", note: "物理按下（咔哒）", value: t[.clickPress]),
            RankRow(id: "tap", label: "轻点", note: "轻点来点按", value: t[.clickTap]),
            RankRow(id: "heavy", label: "重按", note: "第二档深按（阈值待复测）", value: t[.clickHeavy]),
            RankRow(id: "right", label: "右键", note: "辅助点按", value: t[.clickRight]),
        ].filter { $0.value > 0 }
        return RankList(title: "点击", rows: rows, total: nil, color: Theme.trackpad,
                        hovered: .constant(nil), emptyText: report.isLegacyOnly ? "旧版没有区分点击类型" : "暂无")
    }

    private var gestures: some View {
        let t = report.totals
        let rows: [RankRow] = [
            RankRow(id: "point", label: "移动指针", note: "单指移动", value: t[.sessionPoint]),
            RankRow(id: "scroll", label: "双指滚动", note: nil, value: t[.sessionScroll]),
            RankRow(id: "pinch", label: "捏合", note: "双指缩放", value: t[.sessionPinch]),
            RankRow(id: "swipe3", label: "三指", note: "三指轻扫 / 拖移", value: t[.sessionSwipe3]),
            RankRow(id: "swipe4", label: "四指", note: "四指轻扫", value: t[.sessionSwipe4]),
            RankRow(id: "tap", label: "单指轻触", note: nil, value: t[.sessionTap]),
        ].filter { $0.value > 0 }
        return RankList(title: "手势（近似）", rows: rows, total: rows.map(\.value).reduce(0, +),
                        color: Theme.trackpad.opacity(0.7), hovered: .constant(nil),
                        emptyText: report.isLegacyOnly ? "旧版没有手势数据" : "暂无")
    }
}

/// 触控板形状 + 平滑热力面。热力面在后台算好成图像再显示。
struct TrackpadSurface: View {
    let grid: [Double]
    @Binding var hover: CGPoint?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // 内置触控板约 16:10
        AspectBox(ratio: 1.6) {
        GeometryReader { geo in
            let shape = RoundedRectangle(cornerRadius: geo.size.height * 0.07, style: .continuous)
            ZStack {
                shape.fill(Theme.keycap)
                if let image = TrackpadImage.cached(grid: grid, dark: scheme == .dark) {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                }
                if let p = hover {
                    Circle().stroke(Theme.primary.opacity(0.4), lineWidth: 1)
                        .frame(width: 18, height: 18)
                        .position(x: p.x * geo.size.width, y: p.y * geo.size.height)
                }
            }
            .clipShape(shape)
            .overlay(shape.stroke(Theme.hairline, lineWidth: 0.8))
            .onContinuousHover { phase in
                switch phase {
                case .active(let loc):
                    hover = CGPoint(x: min(max(loc.x / geo.size.width, 0), 1),
                                    y: min(max(loc.y / geo.size.height, 0), 1))
                case .ended:
                    hover = nil
                }
            }
        }
        }
    }
}

enum TrackpadImage {
    private struct Key: Hashable { let grid: [Double]; let dark: Bool }
    private static let lock = NSLock()
    private static var cache: [Key: CGImage] = [:]
    private static var order: [Key] = []

    /// 同一份网格只算一次（平滑约几毫秒；库每 15 秒才变一次）。
    static func cached(grid: [Double], dark: Bool) -> CGImage? {
        let key = Key(grid: grid, dark: dark)
        lock.lock()
        if let hit = cache[key] { lock.unlock(); return hit }
        lock.unlock()
        guard let image = render(grid: grid, dark: dark) else { return nil }
        lock.lock()
        cache[key] = image
        order.append(key)
        if order.count > 8 { cache[order.removeFirst()] = nil }
        lock.unlock()
        return image
    }

    /// 把平滑后的密度场映射成珊瑚红色阶（透明度随密度），生成 CGImage。
    static func render(grid: [Double], dark: Bool) -> CGImage? {
        guard grid.contains(where: { $0 > 0 }) else { return nil }
        let field = TouchDensity.field(grid: grid)
        let stops = Theme.trackpadRampRGB.map { dark ? $0.dark : $0.light }
        var pixels = [UInt8](repeating: 0, count: field.width * field.height * 4)
        for i in field.values.indices {
            let v = field.values[i]
            guard v > 0.02 else { continue }
            let pos = v * Double(stops.count - 1)
            let lo = min(Int(pos), stops.count - 1)
            let hi = min(lo + 1, stops.count - 1)
            let f = pos - Double(lo)
            let r = stops[lo].0 + (stops[hi].0 - stops[lo].0) * f
            let g = stops[lo].1 + (stops[hi].1 - stops[lo].1) * f
            let b = stops[lo].2 + (stops[hi].2 - stops[lo].2) * f
            let a = min(1, 0.15 + v * 0.95)
            // 预乘 alpha
            pixels[i * 4] = UInt8(r * a * 255)
            pixels[i * 4 + 1] = UInt8(g * a * 255)
            pixels[i * 4 + 2] = UInt8(b * a * 255)
            pixels[i * 4 + 3] = UInt8(a * 255)
        }
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: field.width, height: field.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: field.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}
