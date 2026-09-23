import SwiftUI
import Charts
import InputscapeKit

// MARK: - 触控板操作

struct TrackpadOpsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    compositionCard
                    hourlyCard
                }
                rankingCard
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("触控板操作构成")
                .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
            Text("点击、滚动、缩放、滑动与 Force Touch 的聚合构成。")
                .font(.system(size: 14)).foregroundColor(Theme.secondary)
            StateBanner(status: model.status,
                        permission: model.permission,
                        deviceConfirmed: model.deviceProfile.confirmed,
                        supportsForceTouch: model.deviceProfile.supportsForceTouch)
        }
    }

    private var snapshot: AggregateSnapshot { model.snapshot }

    private var compositionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("操作构成").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if snapshot.trackpadOps == 0 {
                    EmptyStateView(title: "还没有触控操作记录",
                                   detail: "开始观察后，这里会展示点击、滚动、缩放、滑动等操作的构成。")
                    .frame(height: 160)
                } else {
                    ForEach(TrackpadOperationKind.allCases, id: \.self) { kind in
                        let count = snapshot.trackpadCounts[kind] ?? 0
                        let fraction = snapshot.trackpadOps > 0 ? Double(count) / Double(snapshot.trackpadOps) : 0
                        row(kind: kind, count: count, fraction: fraction)
                    }
                }
            }
        }
    }

    private func row(kind: TrackpadOperationKind, count: Int, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(kind.isScroll ? Theme.coral.opacity(0.65) : Theme.coral)
                    .frame(width: 8, height: 8)
                Text(kind.label).font(.system(size: 13)).foregroundColor(Theme.navy)
                Spacer()
                Text("\(formatCount(count)) 次 · \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.coralSoft)
                    if count > 0 {
                        Capsule().fill(Theme.coral)
                            .frame(width: max(8, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label) \(count) 次，占比 \(Int((fraction * 100).rounded()))%")
    }

    private var hourlyCard: some View {
        let points = hourlyPoints
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("发生时段").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                Text("各操作在一天 24 小时中的分布（\(model.rangeLabel)）。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                if points.allSatisfy({ $0.count == 0 }) {
                    EmptyStateView(title: "暂无时段数据", detail: "观察进行中时会按小时累计各类操作。")
                        .frame(height: 160)
                } else {
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("小时", p.hourLabel),
                                    y: .value("次数", p.count))
                                .foregroundStyle(Theme.coral.opacity(0.85))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: ["00", "06", "12", "18", "23"]) { value in
                            AxisValueLabel() {
                                if let hour = value.as(String.self) {
                                    Text("\(hour)时").font(.system(size: 10))
                                }
                            }
                            .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    private struct HourPoint: Identifiable {
        let hour: Int
        let count: Int
        var hourLabel: String { String(format: "%02d", hour) }
        var id: Int { hour }
    }

    private var hourlyPoints: [HourPoint] {
        var merged = Array(repeating: 0, count: 24)
        for (_, series) in snapshot.hourlyByOp {
            for (i, v) in series.enumerated() where i < 24 { merged[i] += v }
        }
        return (0..<24).map { HourPoint(hour: $0, count: merged[$0]) }
    }

    private var rankingCard: some View {
        let ranking = snapshot.trackpadRanking
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top 操作排行").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if ranking.isEmpty {
                    Text("暂无数据。").font(.system(size: 13)).foregroundColor(Theme.secondary)
                } else {
                    ForEach(Array(ranking.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.tertiary)
                                .frame(width: 18)
                            Text(entry.kind.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.navy)
                            Spacer()
                            Text("\(formatCount(entry.count)) 次")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.coral)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }
}

// MARK: - 使用趋势

struct TrendsView: View {
    @EnvironmentObject var model: AppModel
    @State private var rangeDays = 7
    @State private var selectedDay: String?
    @State private var localSnapshot: AggregateSnapshot = .empty(.last7Days)

    private func reload() {
        localSnapshot = model.snapshotForTrends(dayCount: rangeDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    chartCard
                    detailCard.frame(width: 280)
                }
            }
            .padding(20)
        }
        .onAppear {
            reload()
            if selectedDay == nil { selectedDay = localSnapshot.daySeries.last?.date }
        }
        .onChange(of: rangeDays) { _ in
            reload()
            selectedDay = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("逐日使用趋势")
                    .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
                Text("按日展示键盘与触控操作量，选中日期查看详情。")
                    .font(.system(size: 14)).foregroundColor(Theme.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach([7, 30], id: \.self) { days in
                    Button {
                        rangeDays = days
                        if days == 30 { selectedDay = nil } else { selectedDay = nil }
                    } label: {
                        Text("\(days) 天")
                            .font(.system(size: 13, weight: rangeDays == days ? .semibold : .regular))
                            .foregroundColor(rangeDays == days ? Theme.keyPurple : Theme.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(rangeDays == days ? Theme.keyPurpleSoft : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.background))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private var series: [DaySeriesPoint] {
        Array(localSnapshot.daySeries.suffix(rangeDays))
    }

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("每日输入量").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    Spacer()
                    legend
                }
                if series.isEmpty {
                    EmptyStateView(title: "还没有逐日数据",
                                   detail: "使用几天后，这里会出现按日对比的键盘与触控柱状图。")
                        .frame(height: 220)
                } else {
                    Chart(series) { point in
                        BarMark(x: .value("日期", shortDate(point.date)),
                                y: .value("键盘", point.keyboard))
                            .foregroundStyle(Theme.keyPurple)
                            .opacity(selectedDay == nil || selectedDay == point.date ? 1 : 0.45)
                        BarMark(x: .value("日期", shortDate(point.date)),
                                y: .value("触控", point.trackpad))
                            .foregroundStyle(Theme.coral)
                            .opacity(selectedDay == nil || selectedDay == point.date ? 1 : 0.45)
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let label = value.as(String.self) {
                                    Text(label).font(.system(size: 9))
                                }
                            }
                            .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 220)
                    dayChips
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.keyPurple).frame(width: 9, height: 9)
                Text("键盘").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.coral).frame(width: 9, height: 9)
                Text("触控").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        }
    }

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(series.reversed()) { point in
                    Button {
                        selectedDay = selectedDay == point.date ? nil : point.date
                    } label: {
                        Text(shortDate(point.date))
                            .font(.system(size: 11, weight: selectedDay == point.date ? .semibold : .regular))
                            .foregroundColor(selectedDay == point.date ? .white : Theme.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selectedDay == point.date ? Theme.keyPurple : Theme.background))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var detailCard: some View {
        let point = series.first { $0.date == selectedDay }
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(point?.date ?? "未选择日期")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if let point {
                    detailRow(icon: "keyboard", color: Theme.keyPurple, title: "按键",
                              value: "\(formatCount(point.keyboard)) 次")
                    detailRow(icon: "cursorarrow.click", color: Theme.coral, title: "触控操作",
                              value: "\(formatCount(point.trackpad)) 次")
                    detailRow(icon: "clock", color: Theme.navy, title: "活跃输入",
                              value: formatDuration(point.activeSeconds))
                } else {
                    EmptyStateView(title: "选择一个日期",
                                   detail: "点击图表下方的日期标签查看当日详情。")
                }
            }
        }
    }

    private func detailRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 22)
            Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
        }
    }

    private func shortDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])-\(parts[2])"
    }
}
