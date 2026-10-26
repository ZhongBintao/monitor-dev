import SwiftUI
import InputscapeCore
import InputscapeCapture

/// Today：数字条 → 全宽时间轴 → 键盘 + 触控板热力 → 2–3 句结论。任意一天或区间都用这一页。
struct TodayView: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureSupervisor.self) private var capture
    @Environment(\.database) private var database
    @State private var model = DayReportModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.xl) {
                header
                if let report = model.report {
                    if !report.hasData {
                        EmptyDayCard(isToday: state.isViewingToday, status: capture.status)
                    } else {
                        if report.isLegacyOnly { LegacyBanner() }
                        NumbersStrip(report: report, model: model)
                        if !report.isLegacyOnly {
                            TimelineCard(report: report, model: model)
                        }
                        HeatmapRow(report: report)
                        NotesCard(notes: DayNotes.make(report: report, rhythm: model.singleDayRhythm, now: model.now))
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity, minHeight: 200)
                }
            }
            .padding(Spacing.page)
            .frame(maxWidth: 1480, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(state.isViewingToday ? "今天" : "回看")
        .toolbar { DateToolbar() }
        .onAppear { model.observe(database, range: state.range) }
        .onChange(of: state.range) { _, range in model.observe(database, range: range) }
        .onChange(of: model.now) { _, _ in
            // 跨过 04:00：跟随「今天」时切到新的一天
            if state.pinnedRange == nil { model.observe(database, range: state.range) }
        }
        .onDisappear { model.stop() }
    }

    private var header: some View {
        let range = state.range
        return VStack(alignment: .leading, spacing: 4) {
            Text(title(range)).font(.system(size: 28, weight: .bold))
            Text(subtitle(range)).font(.subheadline).foregroundStyle(Theme.secondary)
        }
    }

    private func title(_ range: DayRange) -> String {
        if range.isSingleDay { return Format.dayTitle(range.start.date) }
        return "\(Format.shortDay(range.start.date)) – \(Format.shortDay(range.end.date))"
    }

    private func subtitle(_ range: DayRange) -> String {
        if range.isSingleDay {
            return range.start == .today() ? "今天 · 逻辑日从凌晨 4 点开始" : "逻辑日 04:00 – 次日 04:00"
        }
        return "\(range.dayCount) 天 · 时间轴为日均分布"
    }
}

// MARK: - 工具栏：日期切换

struct DateToolbar: ToolbarContent {
    @Environment(AppState.self) private var state

    var body: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { state.step(days: -1) } label: { Image(systemName: "chevron.left") }
                .help("前一天")
            Button("今天") { state.show(.single(.today())) }
                .disabled(state.isViewingToday)
            Button { state.step(days: 1) } label: { Image(systemName: "chevron.right") }
                .help("后一天")
                .disabled(state.range.end >= .today())
            Menu {
                Button("最近 7 天") { state.show(DayRange(LogicalDay.today().adding(days: -6), .today())) }
                Button("最近 30 天") { state.show(DayRange(LogicalDay.today().adding(days: -29), .today())) }
            } label: {
                Image(systemName: "calendar.badge.clock")
            }
            .help("区间")
        }
    }
}

// MARK: - 数字条

struct NumbersStrip: View {
    let report: DayReport
    let model: DayReportModel

    var body: some View {
        let days = max(1, report.range.dayCount)
        let longest = model.longestStretch
        HStack(alignment: .top, spacing: 0) {
            metric("活跃时长", Format.duration(seconds: report.activeSeconds),
                   days > 1 ? "日均 \(Format.duration(seconds: report.activeSeconds / Double(days)))"
                            : stretchesNote)
            divider
            metric("最长连续", longest.map { Format.duration(seconds: Double($0.length) * 60) } ?? "—",
                   longest.map { "\(Format.clock(minute: $0.start))–\(Format.clock(minute: $0.end))" + (model.longStretchCount > 0 ? " · \(model.longStretchCount) 段超 1 小时" : "") }
                   ?? (report.isLegacyOnly ? "旧版没有分钟数据" : "还没有连续段"))
            divider
            metric("按键", Format.number(report.keyPresses), keysNote)
            divider
            metric("点击", Format.number(report.clicks), clicksNote)
            divider
            metric("滚动", report.totals.scrollPixels > 0 ? Format.distance(pixels: report.totals.scrollPixels) : "—",
                   report.totals[.scrollMomentumPx] > 0 ? "另有惯性 \(Format.distance(pixels: report.totals[.scrollMomentumPx]))" : "手指滑动距离")
        }
        .frame(height: 74)
        .padding(.vertical, Spacing.l)
        .background(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: Radius.card, style: .continuous).stroke(Theme.hairline.opacity(0.6), lineWidth: 0.5))
    }

    private var stretchesNote: String {
        let n = model.stretchCount
        if report.isLegacyOnly { return "旧版口径，偏低" }
        return n > 0 ? "\(n) 段连续操作" : "—"
    }

    private var keysNote: String {
        var parts: [String] = []
        if let share = report.chineseShare { parts.append("中文 \(Format.percent(share))") }
        let repeats = Int(report.totals[.keyRepeat])
        if repeats > 0 { parts.append("按住重复 \(Format.compact(Double(repeats))) 未计") }
        return parts.isEmpty ? "物理按键次数" : parts.joined(separator: " · ")
    }

    private var clicksNote: String {
        let t = report.totals
        guard t.clicks > 0 else { return "触控板点击" }
        var parts = ["按下 \(Int(t[.clickPress]))", "轻点 \(Int(t[.clickTap]))"]
        if t[.clickHeavy] > 0 { parts.append("重按 \(Int(t[.clickHeavy]))") }
        return parts.joined(separator: " · ")
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 0.5).padding(.vertical, 4)
    }

    private func metric(_ label: String, _ value: String, _ note: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(Theme.secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.l)
    }
}

// MARK: - 热力图行（宽屏并排，窄屏上下）

struct HeatmapRow: View {
    let report: DayReport

    var body: some View {
        AdaptiveRow(breakpoint: 1000, leadingFraction: 0.62, spacing: Spacing.l) {
            KeyboardPanel(report: report)
            TrackpadPanel(report: report)
        }
    }
}

// MARK: - 结论 / 空态

struct NotesCard: View {
    let notes: [String]

    var body: some View {
        if !notes.isEmpty {
            Card("今天的观察") {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(notes, id: \.self) { note in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(Theme.keyboard).frame(width: 5, height: 5).offset(y: -2)
                            Text(note).font(.body)
                        }
                    }
                }
            }
        }
    }
}

struct LegacyBanner: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath").foregroundStyle(Theme.warn)
            Text("旧版记录：只有全天总量，没有时间轴与输入源；按住重复被算作按键，活跃时长偏低。")
                .font(.callout).foregroundStyle(Theme.secondary)
        }
        .padding(Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Radius.small).fill(Theme.warn.opacity(0.08)))
    }
}

struct EmptyDayCard: View {
    let isToday: Bool
    let status: CaptureSupervisor.Status

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(isToday ? "今天还没有数据" : "这一天没有记录").font(.title3.weight(.semibold))
                Text(message).foregroundStyle(Theme.secondary)
            }
            .padding(.vertical, Spacing.xl)
        }
    }

    private var message: String {
        guard isToday else { return "Inputscape 当天没有在运行。" }
        switch status {
        case .noPermission: return "需要在「系统设置 › 隐私与安全性」里允许输入监控与辅助功能，授权后会自动开始记录。"
        case .paused: return "记录已暂停，点侧栏底部的 ▶ 继续。"
        default: return "正在记录。敲几下键盘、用一下触控板，15 秒内这里就会出现第一批数据。"
        }
    }
}
