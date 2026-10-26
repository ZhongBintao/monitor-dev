import SwiftUI
import InputscapeCore
import InputscapeCapture

/// 菜单栏一瞥：今天的活跃时长、当前连续段、最长连续段、24 小时迷你条、暂停、打开主窗口。
struct MenuBarGlance: View {
    @Environment(CaptureSupervisor.self) private var capture
    @Environment(\.database) private var database
    @Environment(\.openWindow) private var openWindow
    @State private var model = DayReportModel()

    var body: some View {
        let report = model.report
        let rhythm = model.singleDayRhythm
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("今天").font(.headline)
                Spacer()
                Circle().fill(capture.status == .recording ? Theme.ok : Theme.rest).frame(width: 7, height: 7)
                Text(capture.status.label).font(.caption).foregroundStyle(Theme.secondary)
            }
            HStack(alignment: .top, spacing: 16) {
                stat("活跃", Format.duration(seconds: report?.activeSeconds ?? 0))
                stat("当前连续", rhythm?.current.map { Format.duration(seconds: Double($0.length) * 60) } ?? "—")
                stat("最长连续", rhythm?.longest.map { Format.duration(seconds: Double($0.length) * 60) } ?? "—")
            }
            if let current = rhythm?.current, current.length > Rhythm.longStretchMinutes {
                Text("已经连续 \(Format.duration(seconds: Double(current.length) * 60)) 没有休息")
                    .font(.caption).foregroundStyle(Theme.warn)
            }
            MiniDayStrip(report: report)
                .frame(height: 28)
            HStack {
                Text("按键 \(Format.number(report?.keyPresses ?? 0)) · 点击 \(Format.number(report?.clicks ?? 0))")
                    .font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                Spacer()
            }
            Divider()
            HStack {
                if capture.status == .recording || capture.status == .paused {
                    Button(capture.status == .recording ? "暂停" : "继续") {
                        capture.setPaused(capture.status == .recording)
                    }
                }
                Spacer()
                Button("打开 Inputscape") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                .keyboardShortcut(.defaultAction)
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
        .onAppear { model.observe(database, range: .single(.today())) }
        .onDisappear { model.stop() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.secondary)
            Text(value).font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
        }
    }
}

/// 24 小时迷你条（04:00 → 次日 04:00）：每 15 分钟一格，深浅 = 活跃秒数。
struct MiniDayStrip: View {
    let report: DayReport?

    var body: some View {
        Canvas { ctx, size in
            guard let report else { return }
            let start = report.range.start.minuteRange.lowerBound
            let slots = 96
            var active = [Double](repeating: 0, count: slots)
            for (m, c) in report.minutes {
                let i = (m - start) / 15
                if active.indices.contains(i) { active[i] += c[.activeSeconds] }
            }
            let w = size.width / CGFloat(slots)
            for i in 0..<slots {
                let level = HeatScale.level(active[i], max: 15 * 60)
                let rect = CGRect(x: CGFloat(i) * w, y: 0, width: max(1, w - 1), height: size.height)
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5),
                         with: .color(level == 0 ? Theme.rest.opacity(0.35) : Theme.keyboardRamp[level]))
            }
            // 当前时刻
            let nowMinute = Int(Date().timeIntervalSince1970 / 60)
            let x = CGFloat(nowMinute - start) / CGFloat(24 * 60) * size.width
            if x > 0 && x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1.5, height: size.height)), with: .color(Theme.primary.opacity(0.6)))
            }
        }
        .overlay(alignment: .bottomLeading) {
            HStack {
                Text("04").font(.system(size: 8)); Spacer(); Text("12").font(.system(size: 8)); Spacer()
                Text("20").font(.system(size: 8)); Spacer(); Text("04").font(.system(size: 8))
            }
            .foregroundStyle(Theme.tertiary)
            .offset(y: 11)
        }
    }
}
