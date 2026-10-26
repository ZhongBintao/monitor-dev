import SwiftUI
import Charts
import InputscapeCore

/// 全宽日时间轴：上方按键 / 5 分钟，下方触控板移动秒数 / 5 分钟（各自独立刻度），
/// 灰带 = 休息（≥ 5 分钟），浅色 = 未记录，深夜轻微着色，括号标出最长连续段。
struct TimelineCard: View {
    let report: DayReport
    let model: DayReportModel

    @State private var selection: Date?

    private static let bucketMinutes = 5

    struct Bucket: Identifiable {
        let start: Date
        let keys: Double
        let trackpad: Double
        var id: Date { start }
    }

    var body: some View {
        let data = TimelineData(report: report, model: model, bucketMinutes: Self.bucketMinutes)
        Card("节奏", subtitle: data.isAverage ? "多日平均" : nil) {
            legend
        } content: {
            chart(data)
                .frame(height: 200)
        }
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(Theme.keyboard, "按键")
            legendItem(Theme.trackpad, "触控板移动")
            legendItem(Color.gray.opacity(0.25), "休息")
            legendItem(Theme.rest.opacity(0.5), "未记录")
        }
        .font(.caption)
        .foregroundStyle(Theme.secondary)
    }

    private func legendItem(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    @ChartContentBuilder
    private func bands(_ data: TimelineData) -> some ChartContent {
        ForEach(Array(data.unknown.enumerated()), id: \.offset) { _, span in
            RectangleMark(xStart: .value("开始", span.0), xEnd: .value("结束", span.1),
                          yStart: .value("下", -1.15), yEnd: .value("上", 1.15))
                .foregroundStyle(Theme.rest.opacity(0.18))
        }
        ForEach(Array(data.breaks.enumerated()), id: \.offset) { _, span in
            RectangleMark(xStart: .value("开始", span.0), xEnd: .value("结束", span.1),
                          yStart: .value("下", -1.15), yEnd: .value("上", 1.15))
                .foregroundStyle(Color.gray.opacity(0.10))
        }
        if let late = data.lateNight {
            RectangleMark(xStart: .value("开始", late.0), xEnd: .value("结束", late.1),
                          yStart: .value("下", -1.15), yEnd: .value("上", 1.15))
                .foregroundStyle(Theme.keyboard.opacity(0.035))
        }
    }

    private func chart(_ data: TimelineData) -> some View {
        Chart {
            bands(data)
            ForEach(data.buckets) { b in
                if b.keys > 0 {
                    BarMark(x: .value("时间", b.start, unit: .minute),
                            yStart: .value("基线", 0), yEnd: .value("按键", b.keys / data.maxKeys),
                            width: .ratio(0.8))
                        .foregroundStyle(Theme.keyboard)
                }
                if b.trackpad > 0 {
                    BarMark(x: .value("时间", b.start, unit: .minute),
                            yStart: .value("基线", 0), yEnd: .value("触控板", -b.trackpad / data.maxTrackpad),
                            width: .ratio(0.8))
                        .foregroundStyle(Theme.trackpad)
                }
            }
            RuleMark(y: .value("基线", 0)).foregroundStyle(Theme.hairline).lineStyle(StrokeStyle(lineWidth: 0.5))
            if let longest = data.longest {
                RuleMark(xStart: .value("开始", longest.0), xEnd: .value("结束", longest.1), y: .value("最长", 1.1))
                    .foregroundStyle(Theme.primary.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round))
                    .annotation(position: .top, alignment: .center, spacing: 2) {
                        Text("最长连续 \(Format.shortDuration(minutes: Int(longest.1.timeIntervalSince(longest.0) / 60)))")
                            .font(.caption2).foregroundStyle(Theme.secondary)
                    }
            }
            if let selected = selection, let b = data.bucket(at: selected) {
                RuleMark(x: .value("选中", b.start, unit: .minute))
                    .foregroundStyle(Theme.secondary.opacity(0.5))
                    .annotation(position: .top, spacing: 0, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(b, data: data)
                    }
            }
        }
        .chartXScale(domain: data.domain)
        .chartYScale(domain: -1.25...1.3)
        .chartYAxis(.hidden)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: data.isLongRange ? 3 : 2)) { _ in
                AxisGridLine().foregroundStyle(Theme.hairline.opacity(0.4))
                AxisValueLabel(format: .dateTime.hour(.twoDigits(amPM: .omitted)))
            }
        }
        .chartXSelection(value: $selection)
        .chartPlotStyle { $0.clipped() }
        .overlay(alignment: .topLeading) {
            Text("按键").font(.caption2).foregroundStyle(Theme.keyboard).padding(.leading, 2)
        }
        .overlay(alignment: .bottomLeading) {
            Text("触控板").font(.caption2).foregroundStyle(Theme.trackpad).padding(.leading, 2).padding(.bottom, 22)
        }
    }

    private func tooltip(_ b: Bucket, data: TimelineData) -> some View {
        let end = b.start.addingTimeInterval(Double(Self.bucketMinutes) * 60)
        let f = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute()
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(b.start.formatted(f))–\(end.formatted(f))").font(.caption.weight(.semibold))
            Text("按键 \(Int(b.keys.rounded()))").font(.caption)
            Text("触控板移动 \(Int(b.trackpad.rounded())) 秒").font(.caption)
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 6).fill(.regularMaterial))
    }
}

/// 时间轴的数据准备（单日：真实分钟；多日：按一天中的时刻求平均）。
@MainActor
struct TimelineData {
    let buckets: [TimelineCard.Bucket]
    let domain: ClosedRange<Date>
    let breaks: [(Date, Date)]
    let unknown: [(Date, Date)]
    let lateNight: (Date, Date)?
    let longest: (Date, Date)?
    let maxKeys: Double
    let maxTrackpad: Double
    let isAverage: Bool
    let isLongRange: Bool
    private let bucketSeconds: Double

    init(report: DayReport, model: DayReportModel, bucketMinutes: Int) {
        let range = report.range
        let day = range.end  // 多日时画在最后一天的时间轴上
        let dayStart = day.start()
        let dayStartMinute = Int(dayStart.timeIntervalSince1970 / 60)
        let days = Double(range.dayCount)
        bucketSeconds = Double(bucketMinutes) * 60
        isAverage = !range.isSingleDay

        // 分钟 → 当天偏移，按 5 分钟分桶
        var keys = [Double](repeating: 0, count: 24 * 60 / bucketMinutes)
        var pad = keys
        for (minute, c) in report.minutes {
            let offset = ((minute - range.start.minuteRange.lowerBound) % (24 * 60) + 24 * 60) % (24 * 60)
            let i = offset / bucketMinutes
            guard keys.indices.contains(i) else { continue }
            keys[i] += Double(c.keyPresses)
            pad[i] += c[.touchMoveSeconds] + c[.pointerSeconds]
        }
        if days > 1 {
            keys = keys.map { $0 / days }
            pad = pad.map { $0 / days }
        }
        var out: [TimelineCard.Bucket] = []
        for i in keys.indices where keys[i] > 0 || pad[i] > 0 {
            out.append(.init(start: dayStart.addingTimeInterval(Double(i * bucketMinutes) * 60),
                             keys: keys[i], trackpad: pad[i]))
        }
        buckets = out
        maxKeys = max(keys.max() ?? 1, 1)
        maxTrackpad = max(pad.max() ?? 1, 1)

        // 显示范围：活动所在时段，至少 08:00–22:00
        let firstIdx = keys.indices.first { keys[$0] > 0 || pad[$0] > 0 }
        let lastIdx = keys.indices.last { keys[$0] > 0 || pad[$0] > 0 }
        let minStart = 4 * 60 / bucketMinutes   // 08:00（逻辑日起点 04:00 后 4 小时）
        let minEnd = 18 * 60 / bucketMinutes    // 22:00
        let startIdx = min(firstIdx.map { ($0 / 12) * 12 } ?? minStart, minStart)
        let endIdx = max(lastIdx.map { ($0 / 12 + 1) * 12 } ?? minEnd, minEnd)
        let lower = dayStart.addingTimeInterval(Double(startIdx * bucketMinutes) * 60)
        let upper = dayStart.addingTimeInterval(Double(min(endIdx, keys.count) * bucketMinutes) * 60)
        domain = lower...upper
        isLongRange = upper.timeIntervalSince(lower) > 18 * 3600

        func date(_ minute: Int) -> Date { Date(timeIntervalSince1970: Double(minute) * 60) }
        if range.isSingleDay, let r = model.rhythms[day] {
            breaks = r.breaks.map { (date($0.start), date($0.end)) }
            unknown = r.unknown.filter { $0.length >= 5 }.map {
                (max(date($0.start), lower), min(date($0.end), upper))
            }.filter { $0.0 < $0.1 }
            longest = r.longest.map { (date($0.start), date($0.end)) }
        } else {
            breaks = []
            unknown = []
            longest = nil
        }
        let lateStart = date(dayStartMinute + Rhythm.lateNightOffsetMinutes)
        lateNight = lateStart < upper ? (lateStart, upper) : nil
    }

    func bucket(at date: Date) -> TimelineCard.Bucket? {
        buckets.first { date >= $0.start && date < $0.start.addingTimeInterval(bucketSeconds) }
    }
}
