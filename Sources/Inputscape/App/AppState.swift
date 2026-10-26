import SwiftUI
import Observation
import InputscapeCore

/// 界面状态：当前页面、Today 查看的日期区间。
@MainActor
@Observable
final class AppState {

    enum Page: String, CaseIterable, Identifiable, Hashable {
        case today, history, live, settings, lab
        var id: String { rawValue }

        var title: String {
            switch self {
            case .today: return "今天"
            case .history: return "历史"
            case .live: return "实时"
            case .settings: return "设置"
            case .lab: return "信号实验室"
            }
        }

        var icon: String {
            switch self {
            case .today: return "sun.max"
            case .history: return "calendar"
            case .live: return "dot.radiowaves.left.and.right"
            case .settings: return "gearshape"
            case .lab: return "flask"
            }
        }
    }

    var page: Page? = .today
    /// nil = 跟随「今天」（跨过 04:00 自动换日）
    var pinnedRange: DayRange?
    var databaseError: String?

    var showLab: Bool = UserDefaults.standard.bool(forKey: "showLab") {
        didSet { UserDefaults.standard.set(showLab, forKey: "showLab") }
    }

    var range: DayRange { pinnedRange ?? .single(.today()) }
    var isViewingToday: Bool { pinnedRange == nil || pinnedRange == .single(.today()) }

    func show(_ range: DayRange) {
        pinnedRange = range == .single(.today()) ? nil : range
        page = .today
    }

    func step(days: Int) {
        let r = range
        let span = r.dayCount
        let newStart = r.start.adding(days: days * span)
        let newEnd = r.end.adding(days: days * span)
        guard newStart <= .today() else { return }
        show(DayRange(newStart, min(newEnd, .today())))
    }
}
