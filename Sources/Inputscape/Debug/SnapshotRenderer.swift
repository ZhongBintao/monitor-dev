import SwiftUI
import AppKit
import InputscapeCore
import InputscapeStore
import InputscapeCapture

/// 开发用：`Inputscape --snapshot <目录> [yyyy-MM-dd]` 用真实数据把主要页面离屏渲染成 PNG（浅色 + 深色）后退出。
/// 不启动采集，不写库。用于在没有屏幕录制权限时检查布局。
@MainActor
enum SnapshotRenderer {

    static var requestedDirectory: URL? {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return nil }
        return URL(fileURLWithPath: args[i + 1], isDirectory: true)
    }

    static var requestedDay: LogicalDay {
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--snapshot"), i + 2 < args.count, let d = LogicalDay(id: args[i + 2]) { return d }
        return .today()
    }

    static func run(into dir: URL, environment env: AppEnvironment) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let day = requestedDay
        let pages: [(String, DayRange)] = [
            ("today", .single(day)),
            ("week", DayRange(day.adding(days: -6), day)),
            ("legacy", .single(LogicalDay(id: "2026-10-02") ?? day)),
        ]
        for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            NSApp.appearance = NSAppearance(named: appearance)
            for (name, range) in pages {
                guard let report = try? env.database.report(range: range) else { continue }
                let model = DayReportModel()
                model.load(report)
                render(TodaySnapshot(report: report, model: model, range: range)
                        .environment(\.colorScheme, scheme == "dark" ? .dark : .light),
                       width: 1240, to: dir.appendingPathComponent("\(name)-\(scheme).png"))
            }
            let history = HistorySnapshot(database: env.database)
                .environment(\.colorScheme, scheme == "dark" ? .dark : .light)
            render(history, width: 1240, to: dir.appendingPathComponent("history-\(scheme).png"))
            render(MenuSnapshot(database: env.database).environment(\.colorScheme, scheme == "dark" ? .dark : .light),
                   width: 320, to: dir.appendingPathComponent("menubar-\(scheme).png"))
        }
    }

    private static func render<V: View>(_ view: V, width: CGFloat, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: width).background(Theme.window))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
    }
}

/// Today 页内容（不含 ScrollView，ImageRenderer 不渲染滚动视图）。
private struct TodaySnapshot: View {
    let report: DayReport
    let model: DayReportModel
    let range: DayRange

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xl) {
            VStack(alignment: .leading, spacing: 4) {
                Text(range.isSingleDay ? Format.dayTitle(range.start.date)
                     : "\(Format.shortDay(range.start.date)) – \(Format.shortDay(range.end.date))")
                    .font(.system(size: 28, weight: .bold))
                Text("快照").font(.subheadline).foregroundStyle(Theme.secondary)
            }
            if report.hasData {
                if report.isLegacyOnly { LegacyBanner() }
                NumbersStrip(report: report, model: model)
                if !report.isLegacyOnly { TimelineCard(report: report, model: model) }
                HeatmapRow(report: report)
                NotesCard(notes: DayNotes.make(report: report, rhythm: model.singleDayRhythm))
            } else {
                EmptyDayCard(isToday: true, status: .recording)
            }
        }
        .padding(Spacing.page)
    }
}

private struct HistorySnapshot: View {
    let database: InputscapeDatabase

    var body: some View {
        let today = LogicalDay.today()
        let range = DayRange(today.adding(days: -(HistoryModel.weeks * 7 - 1)), today)
        let days = (try? database.writer.read { try Queries.daySummaries($0, range: range) }) ?? []
        let hourly = (try? database.writer.read { try Queries.hourly($0, range: range) }) ?? [:]
        VStack(alignment: .leading, spacing: Spacing.xl) {
            Text("历史").font(.system(size: 28, weight: .bold))
            Card("活跃时长", subtitle: "近一年 · 斜线为旧版数据") {
                CalendarLegend()
            } content: {
                CalendarHeatmap(days: days, weeks: HistoryModel.weeks) { _, _ in }
            }
            WeekComparison(days: days)
            HStack(alignment: .top, spacing: Spacing.l) {
                HourWeekdayGrid(hourly: hourly)
                LanguageShareChart(days: days)
            }
        }
        .padding(Spacing.page)
    }
}

private struct MenuSnapshot: View {
    let database: InputscapeDatabase
    var body: some View {
        let report = try? database.report(range: .single(.today()))
        VStack(alignment: .leading, spacing: 10) {
            Text("今天 · 活跃 \(Format.duration(seconds: report?.activeSeconds ?? 0))").font(.headline)
            MiniDayStrip(report: report).frame(height: 28)
        }
        .padding(14)
    }
}
