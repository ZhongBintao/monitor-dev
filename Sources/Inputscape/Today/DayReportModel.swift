import SwiftUI
import Observation
import InputscapeCore
import InputscapeStore

/// 订阅某个日期区间的报告：库一变（每 15 秒写一次）就自动刷新，无需轮询。
@MainActor
@Observable
final class DayReportModel {

    private(set) var report: DayReport?
    private(set) var rhythms: [LogicalDay: Rhythm.Summary] = [:]
    private(set) var loadedRange: DayRange?
    /// 每分钟走一次，用来更新「进行中的连续段」和跨 04:00 换日
    private(set) var now = Date()

    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var ticker: Timer?

    func observe(_ database: InputscapeDatabase?, range: DayRange) {
        guard let database, range != loadedRange else { return }
        loadedRange = range
        task?.cancel()
        report = nil
        task = Task { [weak self] in
            do {
                for try await value in database.observeReport(range: range) {
                    guard let self, !Task.isCancelled else { return }
                    self.report = value
                    self.recomputeRhythm()
                }
            } catch {
                NSLog("Inputscape: report observation failed: \(error)")
            }
        }
        if ticker == nil {
            let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.now = Date()
                    self?.recomputeRhythm()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            ticker = timer
        }
    }

    /// 直接载入一份报告（离屏快照用）。
    func load(_ report: DayReport) {
        loadedRange = report.range
        self.report = report
        recomputeRhythm()
    }

    func stop() {
        task?.cancel()
        task = nil
        ticker?.invalidate()
        ticker = nil
        loadedRange = nil
    }

    private func recomputeRhythm() {
        guard let report else { rhythms = [:]; return }
        var out: [LogicalDay: Rhythm.Summary] = [:]
        for day in report.range.days where !report.legacy.contains(where: { $0.day == day }) {
            out[day] = report.rhythm(for: day, now: now)
        }
        rhythms = out
    }

    // MARK: 区间汇总

    /// 区间内最长的连续段（跨天比较）。
    var longestStretch: Rhythm.Stretch? {
        rhythms.values.compactMap(\.longest).max { $0.length < $1.length }
    }

    var longStretchCount: Int { rhythms.values.map { $0.longStretches.count }.reduce(0, +) }
    var lateNightMinutes: Int { rhythms.values.map(\.lateNightMinutes).reduce(0, +) }
    var stretchCount: Int { rhythms.values.map(\.stretches.count).reduce(0, +) }

    var singleDayRhythm: Rhythm.Summary? {
        guard let r = loadedRange, r.isSingleDay else { return nil }
        return rhythms[r.start]
    }
}
