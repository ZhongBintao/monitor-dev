import SwiftUI
import Charts
import Observation
import InputscapeCore
import InputscapeStore

@MainActor
@Observable
final class HistoryModel {
    private(set) var data = InputscapeDatabase.HistoryData()
    private(set) var range: DayRange?
    @ObservationIgnored private var task: Task<Void, Never>?

    /// 近一年
    static let weeks = 53

    func observe(_ database: InputscapeDatabase?) {
        guard let database else { return }
        let today = LogicalDay.today()
        let r = DayRange(today.adding(days: -(Self.weeks * 7 - 1)), today)
        guard r != range else { return }
        range = r
        task?.cancel()
        task = Task { [weak self] in
            do {
                for try await value in database.observeHistory(range: r) {
                    guard let self, !Task.isCancelled else { return }
                    self.data = value
                }
            } catch {
                NSLog("Inputscape: history observation failed: \(error)")
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        range = nil
    }

    func summary(for day: LogicalDay) -> DaySummary? {
        data.days.first { $0.day == day }
    }
}

/// 历史：日历热力 → 本周对比 → 小时 × 星期 → 中文输入占比。
struct HistoryView: View {
    @Environment(AppState.self) private var state
    @Environment(\.database) private var database
    @State private var model = HistoryModel()
    @State private var anchor: LogicalDay?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("历史").font(.system(size: 28, weight: .bold))
                    Text("点一天查看当日；按住 ⇧ 再点另一天选择区间").font(.subheadline).foregroundStyle(Theme.secondary)
                }
                Card("活跃时长", subtitle: "近一年 · 斜线为旧版数据") {
                    CalendarLegend()
                } content: {
                    CalendarHeatmap(days: model.data.days, weeks: HistoryModel.weeks) { day, extend in
                        if extend, let a = anchor {
                            state.show(DayRange(a, day))
                        } else {
                            anchor = day
                            state.show(.single(day))
                        }
                    }
                }
                WeekComparison(days: model.data.days)
                HStack(alignment: .top, spacing: Spacing.l) {
                    HourWeekdayGrid(hourly: model.data.hourly)
                    LanguageShareChart(days: model.data.days)
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("历史")
        .onAppear { model.observe(database) }
        .onDisappear { model.stop() }
    }
}

// MARK: - 日历热力

struct CalendarHeatmap: View {
    let days: [DaySummary]
    let weeks: Int
    let onSelect: (LogicalDay, Bool) -> Void

    @State private var hovered: LogicalDay?

    private static let thresholds: [Double] = [0, 30 * 60, 2 * 3600, 4 * 3600, 6 * 3600]

    var body: some View {
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        let today = LogicalDay.today()
        // 列 = 周（周一开始），行 = 星期
        let todayIndex = (today.weekday + 5) % 7  // 周一 = 0
        let firstDay = today.adding(days: -(todayIndex + (weeks - 1) * 7))

        VStack(alignment: .leading, spacing: 8) {
            // 格子随宽度伸缩：周数列 + 星期标签列
            AspectBox(ratio: (CGFloat(weeks) + 1) / 7.6) {
                GeometryReader { geo in
                    let gap: CGFloat = 3
                    let size = max(6, (geo.size.width - 18) / CGFloat(weeks) - gap)
                    HStack(alignment: .top, spacing: gap) {
                        VStack(spacing: gap) {
                            ForEach(["一", "二", "三", "四", "五", "六", "日"], id: \.self) { d in
                                Text(d).font(.system(size: 9)).foregroundStyle(Theme.tertiary).frame(width: 15, height: size)
                            }
                        }
                        ForEach(0..<weeks, id: \.self) { w in
                            VStack(spacing: gap) {
                                ForEach(0..<7, id: \.self) { d in
                                    let day = firstDay.adding(days: w * 7 + d)
                                    cell(day: day, summary: byDay[day], future: day > today, size: size)
                                }
                            }
                        }
                    }
                }
            }
            monthLabels(firstDay: firstDay)
            Text(hoverText(byDay)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                .frame(height: 16)
        }
    }

    private func level(_ seconds: Double) -> Int {
        guard seconds > 0 else { return 0 }
        return min(5, Self.thresholds.lastIndex { seconds >= $0 }.map { $0 + 1 } ?? 1)
    }

    @ViewBuilder
    private func cell(day: LogicalDay, summary: DaySummary?, future: Bool, size: CGFloat) -> some View {
        let l = level(summary?.activeSeconds ?? 0)
        let shape = RoundedRectangle(cornerRadius: 3, style: .continuous)
        shape
            .fill(future ? Color.clear : Theme.keyboardRamp[l])
            .overlay {
                if summary?.isLegacy == true {
                    // 旧版日：斜线标记
                    Canvas { ctx, size in
                        var p = Path()
                        for x in stride(from: -size.height, to: size.width, by: 4) {
                            p.move(to: CGPoint(x: x, y: size.height))
                            p.addLine(to: CGPoint(x: x + size.height, y: 0))
                        }
                        ctx.stroke(p, with: .color(Theme.primary.opacity(0.25)), lineWidth: 0.7)
                    }
                    .clipShape(shape)
                }
            }
            .overlay(shape.stroke(hovered == day ? Theme.primary : Theme.hairline.opacity(future ? 0.3 : 0.6),
                                  lineWidth: hovered == day ? 1.5 : 0.5))
            .frame(width: size, height: size)
            .contentShape(shape)
            .onHover { inside in hovered = inside ? day : (hovered == day ? nil : hovered) }
            .onTapGesture {
                guard !future else { return }
                onSelect(day, NSEvent.modifierFlags.contains(.shift))
            }
    }

    /// 每月第一周上方标注月份。
    private func monthLabels(firstDay: LogicalDay) -> some View {
        GeometryReader { geo in
            let colWidth = (geo.size.width - 18) / CGFloat(weeks)
            ZStack(alignment: .topLeading) {
                ForEach(0..<weeks, id: \.self) { w in
                    let month = Calendar.current.component(.month, from: firstDay.adding(days: w * 7 + 6).date)
                    let previous = Calendar.current.component(.month, from: firstDay.adding(days: w * 7 - 1).date)
                    if month != previous {
                        Text("\(month) 月")
                            .font(.system(size: 9)).foregroundStyle(Theme.tertiary)
                            .offset(x: 18 + CGFloat(w) * colWidth)
                    }
                }
            }
        }
        .frame(height: 12)
    }

    private func hoverText(_ byDay: [LogicalDay: DaySummary]) -> String {
        guard let day = hovered else { return " " }
        let title = Format.dayTitle(day.date)
        guard let s = byDay[day] else { return "\(title) · 无记录" }
        var text = "\(title) · 活跃 \(Format.duration(seconds: s.activeSeconds)) · 按键 \(Format.number(s.keys)) · 点击 \(Format.number(s.clicks))"
        if s.isLegacy { text += " · 旧版数据" }
        return text
    }
}

struct CalendarLegend: View {
    var body: some View {
        HStack(spacing: 4) {
            Text("0").font(.caption2).foregroundStyle(Theme.tertiary)
            ForEach(1..<6) { l in
                RoundedRectangle(cornerRadius: 2).fill(Theme.keyboardRamp[l]).frame(width: 11, height: 11)
            }
            Text("6 小时+").font(.caption2).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - 本周 vs 上周（同样的星期几）

struct WeekComparison: View {
    let days: [DaySummary]

    var body: some View {
        let today = LogicalDay.today()
        let elapsed = (today.weekday + 5) % 7 + 1      // 本周已过天数（周一起）
        let thisWeek = (0..<elapsed).map { today.adding(days: -$0) }
        let lastWeek = thisWeek.map { $0.adding(days: -7) }
        let byDay = Dictionary(uniqueKeysWithValues: days.map { ($0.day, $0) })
        func total(_ list: [LogicalDay], _ f: (DaySummary) -> Double) -> Double {
            list.compactMap { byDay[$0] }.map(f).reduce(0, +)
        }
        let metrics: [(String, Double, Double, (Double) -> String)] = [
            ("活跃时长", total(thisWeek, \.activeSeconds), total(lastWeek, \.activeSeconds), { Format.duration(seconds: $0) }),
            ("按键", total(thisWeek) { Double($0.keys) }, total(lastWeek) { Double($0.keys) }, { Format.number(Int($0)) }),
            ("点击", total(thisWeek) { Double($0.clicks) }, total(lastWeek) { Double($0.clicks) }, { Format.number(Int($0)) }),
        ]
        return Card("本周", subtitle: "对比上周同样的 \(elapsed) 天") {
            HStack(spacing: Spacing.l) {
                ForEach(metrics, id: \.0) { m in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(m.0).font(.caption).foregroundStyle(Theme.secondary)
                        Text(m.3(m.1)).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                        delta(m.1, m.2, format: m.3)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    @ViewBuilder
    private func delta(_ now: Double, _ before: Double, format: (Double) -> String) -> some View {
        if before > 0 {
            let change = (now - before) / before
            Text("\(change >= 0 ? "↑" : "↓") \(Format.percent(abs(change))) · 上周 \(format(before))")
                .font(.caption).foregroundStyle(Theme.secondary)
        } else {
            Text("上周无记录").font(.caption).foregroundStyle(Theme.tertiary)
        }
    }
}

// MARK: - 小时 × 星期

struct HourWeekdayGrid: View {
    let hourly: [Int: Queries.HourStat]

    struct Cell: Identifiable {
        let weekday: Int   // 0 = 周一
        let hour: Int
        let minutes: Double
        var id: Int { weekday * 24 + hour }
    }

    var body: some View {
        let cells = makeCells()
        let maxValue = cells.map(\.minutes).max() ?? 0
        Card("一周里的时段", subtitle: "每小时平均活跃分钟") {
            if maxValue == 0 {
                Text("新版记录满几天后这里会出现规律。").font(.callout).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(cells) { c in
                    // 两个轴都用数值，周一在最上
                    RectangleMark(xStart: .value("开始", Double(c.hour) - 0.46),
                                  xEnd: .value("结束", Double(c.hour) + 0.46),
                                  yStart: .value("下", Double(6 - c.weekday) - 0.42),
                                  yEnd: .value("上", Double(6 - c.weekday) + 0.42))
                        .foregroundStyle(Theme.keyboardRamp[HeatScale.level(c.minutes, max: maxValue)])
                        .cornerRadius(2)
                }
                .chartXScale(domain: -0.5...23.5)
                .chartXAxis {
                    AxisMarks(values: [0, 4, 8, 12, 16, 20]) { v in
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)时").font(.caption2) }
                    }
                }
                .chartYScale(domain: -0.5...6.5)
                .chartYAxis {
                    AxisMarks(position: .leading, values: Array(0...6)) { v in
                        AxisValueLabel { Text(weekdayName(6 - (v.as(Int.self) ?? 0))).font(.caption2) }
                    }
                }
                .frame(height: 190)
            }
        }
    }

    private func weekdayName(_ i: Int) -> String { ["一", "二", "三", "四", "五", "六", "日"][i] }

    private func makeCells() -> [Cell] {
        var sums = [[Double]](repeating: [Double](repeating: 0, count: 24), count: 7)
        var dayCounts = [Set<LogicalDay>](repeating: [], count: 7)
        let calendar = Calendar.current
        for (hour, stat) in hourly where stat.activeSeconds > 0 {
            let date = Date(timeIntervalSince1970: Double(hour) * 3600)
            let wd = (calendar.component(.weekday, from: date) + 5) % 7
            let h = calendar.component(.hour, from: date)
            sums[wd][h] += stat.activeSeconds / 60
            dayCounts[wd].insert(LogicalDay(containing: date))
        }
        var out: [Cell] = []
        for wd in 0..<7 {
            let n = Double(max(1, dayCounts[wd].count))
            for h in 0..<24 { out.append(Cell(weekday: wd, hour: h, minutes: sums[wd][h] / n)) }
        }
        return out
    }
}

// MARK: - 中文输入占比

struct LanguageShareChart: View {
    let days: [DaySummary]

    var body: some View {
        let recent = days.filter { $0.chineseShare != nil }.suffix(30)
        let end = LogicalDay.today()
        let start = end.adding(days: -29)
        Card("中文输入", subtitle: "中文输入法开启时的按键占比") {
            if recent.isEmpty {
                Text("新版开始记录输入源后显示。").font(.callout).foregroundStyle(Theme.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                Chart(Array(recent)) { d in
                    BarMark(x: .value("日期", d.day.date, unit: .day), y: .value("占比", d.chineseShare ?? 0))
                        .foregroundStyle(Theme.keyboard.opacity(0.8))
                        .cornerRadius(2)
                }
                .chartYScale(domain: 0...1)
                .chartXScale(domain: start.date...end.adding(days: 1).date)
                .chartYAxis {
                    AxisMarks(values: [0, 0.5, 1]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text(Format.percent(v.as(Double.self) ?? 0)).font(.caption2) }
                    }
                }
                .chartXAxis {
                    AxisMarks(values: .stride(by: .day, count: 7)) { _ in
                        AxisValueLabel(format: .dateTime.month(.defaultDigits).day())
                    }
                }
                .frame(height: 190)
            }
        }
    }
}
