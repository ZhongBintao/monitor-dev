import SwiftUI
import Charts
import InputscapeKit

// MARK: - 总览

struct OverviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedTouchCell: TouchHeatmapPanel.Cell?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricsRow
                rhythmCard
                HStack(alignment: .top, spacing: 16) {
                    keyboardSummaryCard
                    trackpadHeatmapCard
                }
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text(periodTitle)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(Theme.navy)
                Text("轻量观察，了解自己的使用习惯。")
                    .font(.system(size: 14))
                    .foregroundColor(Theme.secondary)
            }
            Spacer()
            RefreshButton()
        }
    }

    private var periodTitle: String {
        if model.customRange != nil {
            return "\(model.rangeLabel)，你的输入节奏"
        }
        switch model.scope {
        case .today: return "今天，你的输入节奏"
        case .last7Days: return "近 7 天，你的输入节奏"
        case .last30Days: return "近 30 天，你的输入节奏"
        }
    }

    private var metricsRow: some View {
        let s = model.snapshot
        return Card {
            HStack(spacing: 0) {
                StatCard(icon: "keyboard", value: formatCount(s.keyPresses), title: "按键次数")
                    .frame(maxWidth: .infinity)
                divider
                StatCard(icon: "cursorarrow.click", value: formatCount(s.trackpadOps),
                         title: "触控操作", accent: Theme.coral)
                    .frame(maxWidth: .infinity)
                divider
                StatCard(icon: "clock", value: formatDuration(s.activeSeconds), title: "活跃输入")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var divider: some View {
        Rectangle()
            .fill(Theme.hairline)
            .frame(width: 1, height: 40)
    }

    // MARK: 使用节奏（5 分钟桶，键盘在上、触控在下）

    private var rhythmCard: some View {
        let points = rhythmPoints
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("使用节奏").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                        HelpMarker(text: "键盘输入显示在横轴上方（蓝紫），触控操作显示在下方（珊瑚红）。颜色仅表达密度，具体次数请查看键位与操作排行。")
                    }
                    Text(scopeSubtitle).font(.system(size: 12)).foregroundColor(Theme.secondary)
                }
                if points.isEmpty {
                    EmptyStateView(title: "还没有数据",
                                   detail: "完成首次引导并开始观察后，这里会出现按 5 分钟聚合的输入活动分布。")
                    .frame(height: 150)
                } else {
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("时间", p.date, unit: .minute),
                                    y: .value("键盘", p.keyboard),
                                    width: .fixed(4))
                            .foregroundStyle(Theme.keyPurple.opacity(0.85))
                            BarMark(x: .value("时间", p.date, unit: .minute),
                                    y: .value("触控", -p.trackpad),
                                    width: .fixed(4))
                            .foregroundStyle(Theme.coral.opacity(0.8))
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading, values: [0]) { _ in
                            AxisGridLine().foregroundStyle(Theme.hairline)
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: .stride(by: .hour)) { _ in
                            AxisValueLabel(format: .dateTime.hour().minute())
                                .font(.system(size: 10))
                                .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 150)
                    legend
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.keyPurple).frame(width: 9, height: 9)
                Text("键盘输入（上）").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
            HStack(spacing: 5) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.coral).frame(width: 9, height: 9)
                Text("触控操作（下）").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
            Spacer()
            Text("颜色之外同时提供数字：将鼠标悬停在键位或查看排行可获得具体计数。")
                .font(.system(size: 11)).foregroundColor(Theme.tertiary)
        }
    }

    private var scopeSubtitle: String {
        switch model.scope {
        case .today: return "今天 00:00 起的输入活动分布（每 5 分钟）"
        case .last7Days: return "近 7 天合并的活动分布（每 5 分钟，按一天内时刻）"
        case .last30Days: return "近 30 天合并的活动分布（每 5 分钟，按一天内时刻）"
        }
    }

    private struct RhythmPoint: Identifiable {
        let date: Date
        let keyboard: Int
        let trackpad: Int
        var id: Date { date }
    }

    private var rhythmPoints: [RhythmPoint] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return model.snapshot.buckets.map { bucket in
            RhythmPoint(date: start.addingTimeInterval(TimeInterval(bucket.index * 300)),
                        keyboard: bucket.keyboard,
                        trackpad: bucket.trackpad)
        }
    }

    // MARK: 摘要卡

    private var keyboardSummaryCard: some View {
        let top = model.snapshot.topKeys(1).first
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "键盘分布",
                           trailing: AnyView(PageLink(page: .keyboard, title: "查看键盘分布")))
                KeyboardHeatmapView(values: model.snapshot.keyCounts,
                                    selectedKeyID: $model.selectedKeyID,
                                    reduceMotion: model.reduceMotion,
                                    minUnit: 21)
                    .aspectRatio(KeyboardHeatmapView.canvasAspectRatio, contentMode: .fit)
                if let top {
                    (Text("今天最常用的是 ").foregroundColor(Theme.secondary)
                     + Text(topKeyName(top.id)).foregroundColor(Theme.keyPurple).bold()
                     + Text(" 键。").foregroundColor(Theme.secondary))
                    .font(.system(size: 13))
                } else {
                    Text("暂无按键数据。").font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
                if let combo = model.snapshot.topCombos(1).first {
                    (Text("最常用组合 ").foregroundColor(Theme.secondary)
                     + Text(combo.id).foregroundColor(Theme.keyPurple).bold()
                     + Text("，共 \(formatCount(combo.count)) 次。").foregroundColor(Theme.secondary))
                    .font(.system(size: 13))
                }
            }
        }
    }

    /// 触控板热力图卡（与左侧键盘分布卡配对）：24×16 热力面板 +
    /// 数字色阶图例 + 最热/选中读数。取代原「触控板操作」摘要卡。
    private var trackpadHeatmapCard: some View {
        let snapshot = model.snapshot
        let bounds = HeatLegend.boundaries(maxCount: snapshot.touchGrid.max() ?? 0,
                                           steps: Theme.coralScale.count)
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "触控板热力图",
                           trailing: AnyView(PageLink(page: .trackpad, title: "查看触控板操作")))
                if snapshot.touchTotal == 0 {
                    EmptyStateView(title: "暂无触点数据",
                                   detail: "在触控板上操作后会自动累计触点位置分布。")
                        .frame(height: 170)
                } else {
                    let bounds = HeatLegend.boundaries(maxCount: snapshot.touchGrid.max() ?? 0,
                                                       steps: Theme.coralScale.count)
                    VStack(spacing: 8) {
                        TouchHeatmapPanel(grid: snapshot.touchGrid,
                                          boundaries: bounds,
                                          selectedCell: $selectedTouchCell)
                            .frame(maxWidth: 320)
                        HeatLegendView(scale: Theme.coralScale, boundaries: bounds, style: .relative)
                        TouchHeatmapFootnote(snapshot: snapshot,
                                             boundaries: bounds,
                                             selectedCell: selectedTouchCell)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                }
                if !model.deviceProfile.supportsForceTouch {
                    Text("当前设备不支持重按（Force Touch）。")
                        .font(.system(size: 11)).foregroundColor(Theme.tertiary)
                }
            }
        }
    }

    private func topKeyName(_ id: String) -> String {
        guard let key = KeyboardLayoutSpec.key(withID: id) else { return id }
        if let base = key.baseLabel { return base }
        if let word = key.word { return word.localizedCapitalized }
        return id
    }
}

// MARK: - 页面跳转链接

struct PageLink: View {
    @EnvironmentObject var model: AppModel
    let page: AppModel.Page
    let title: String

    var body: some View {
        Button {
            model.page = page
        } label: {
            HStack(spacing: 3) {
                Text(title)
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .semibold))
            }
            .font(.system(size: 13, weight: .medium))
            .foregroundColor(Theme.keyPurple)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 键盘分布

struct KeyboardDistributionView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedKeyID: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                metricsRow
                HStack(alignment: .top, spacing: 16) {
                    heatmapCard
                    topCard.frame(width: 300)
                }
                detailCard
                combosCard
            }
            .padding(20)
        }
    }

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 4) {
                Text("每一个键，都有自己的频率")
                    .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
                Text("看清你最常用的物理键位。")
                    .font(.system(size: 14)).foregroundColor(Theme.secondary)
            }
            Spacer()
            RefreshButton()
        }
    }

    private var metricsRow: some View {
        let s = model.snapshot
        let scopeTitle = model.customRange == nil && model.scope == .today ? "今日按键" : "期间按键"
        return Card {
            HStack(spacing: 0) {
                StatCard(icon: "keyboard", value: formatCount(s.keyPresses), title: scopeTitle)
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)
                StatCard(icon: "square.grid.3x3", value: "78", title: "物理键区")
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 40)
                StatCard(icon: "clock", value: formatDuration(s.activeSeconds), title: "活跃输入")
                    .frame(maxWidth: .infinity)
            }
        }
    }

    private var heatmapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "键位使用分布",
                           trailing: AnyView(heatLegend))
                Text("颜色越深表示该键位使用越频繁；选中键位可在下方查看具体数字。图例为当前数据的实际次数区间。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                KeyboardHeatmapView(values: model.snapshot.keyCounts,
                                    selectedKeyID: $selectedKeyID,
                                    reduceMotion: model.reduceMotion,
                                    minUnit: 34)
                    .aspectRatio(KeyboardHeatmapView.canvasAspectRatio, contentMode: .fit)
            }
        }
    }

    /// 数字色阶图例：与键盘渲染共用 HeatLegend 分档，标注实际次数区间。
    private var heatLegend: some View {
        let maxCount = model.snapshot.keyCounts.values.max() ?? 0
        return Group {
            if maxCount > 0 {
                HeatLegendView(scale: Theme.heatScale,
                               boundaries: HeatLegend.boundaries(maxCount: maxCount,
                                                                 steps: Theme.heatScale.count))
            }
        }
    }

    private var topCard: some View {
        let top = model.snapshot.topKeys(5)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("常用键位 Top 5").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if top.isEmpty {
                    EmptyStateView(title: "还没有按键记录",
                                   detail: "开始观察后，这里会列出最常用的 5 个物理键位及次数。")
                } else {
                    ForEach(Array(top.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.tertiary)
                                .frame(width: 18)
                            Text(keyName(entry.id))
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.navy)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Theme.keyPurpleSoft))
                            Spacer()
                            Text(formatCount(entry.count))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Theme.navy)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedKeyID = entry.id }
                    }
                }
            }
        }
    }

    private var detailCard: some View {
        let selected = selectedKeyID
        let count = selected.flatMap { model.snapshot.keyCount($0) } ?? 0
        let total = max(model.snapshot.keyPresses, 1)
        return Card {
            HStack(spacing: 0) {
                detailCell(title: "当前键位", value: selected.map { keyName($0) } ?? "未选中")
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 36)
                detailCell(title: "按下次数", value: selected == nil ? "—" : "\(formatCount(count)) 次")
                    .frame(maxWidth: .infinity)
                Rectangle().fill(Theme.hairline).frame(width: 1, height: 36)
                detailCell(title: "占今日按键",
                           value: selected == nil ? "—" : String(format: "%.1f%%", Double(count) / Double(total) * 100))
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: 组合键 Top 5（修饰键按住 + 普通键按下 的和弦统计）

    private var combosCard: some View {
        let combos = model.snapshot.topCombos(5)
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("组合键 Top 5").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "组合 = 修饰键按住时按下普通键（如 ⌘C、⇧⌘3、⌃⌥⌘Delete）；只记录和弦构成，不记录时间序列。fn 与方向键的组合同样计入（fn 按住时方向键的键码会被系统改写，已映射回物理键位）。")
                }
                if combos.isEmpty {
                    Text("暂无组合记录。使用 ⌘C、⇧⌘3 这类快捷键时会自动计入。")
                        .font(.system(size: 13)).foregroundColor(Theme.secondary)
                } else {
                    ForEach(Array(combos.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.tertiary)
                                .frame(width: 18)
                            Text(entry.id)
                                .font(.system(size: 14, weight: .semibold, design: .rounded))
                                .foregroundColor(Theme.navy)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Capsule().fill(Theme.keyPurpleSoft))
                            Spacer()
                            Text(formatCount(entry.count))
                                .font(.system(size: 15, weight: .bold))
                                .foregroundColor(Theme.navy)
                        }
                    }
                }
            }
        }
    }

    private func detailCell(title: String, value: String) -> some View {
        VStack(spacing: 4) {
            Text(title).font(.system(size: 12)).foregroundColor(Theme.secondary)
            Text(value).font(.system(size: 18, weight: .bold)).foregroundColor(Theme.navy)
        }
    }

    private func keyName(_ id: String) -> String {
        guard let key = KeyboardLayoutSpec.key(withID: id) else { return id }
        if let base = key.baseLabel { return base }
        if let word = key.word { return word.localizedCapitalized }
        return id
    }
}
