import SwiftUI
import InputscapeCore
import InputscapeCapture

struct RootView: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureSupervisor.self) private var capture

    var body: some View {
        @Bindable var state = state
        NavigationSplitView {
            List(selection: $state.page) {
                Section {
                    ForEach([AppState.Page.today, .history, .live]) { page in
                        Label(page.title, systemImage: page.icon).tag(page)
                    }
                }
                Section {
                    Label(AppState.Page.settings.title, systemImage: AppState.Page.settings.icon)
                        .tag(AppState.Page.settings)
                    if state.showLab {
                        Label(AppState.Page.lab.title, systemImage: AppState.Page.lab.icon)
                            .tag(AppState.Page.lab)
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
            .safeAreaInset(edge: .bottom) { StatusFooter() }
        } detail: {
            Group {
                switch state.page ?? .today {
                case .today: TodayView()
                case .history: HistoryView()
                case .live: LiveView()
                case .settings: SettingsView()
                case .lab: LabView()
                }
            }
            .frame(minWidth: 860, minHeight: 640)
            .background(Theme.window)
        }
    }
}

/// 侧栏底部：采集状态 + 暂停开关。
struct StatusFooter: View {
    @Environment(CaptureSupervisor.self) private var capture

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(capture.status.label).font(.caption).foregroundStyle(Theme.secondary)
            Spacer()
            if capture.status == .recording || capture.status == .paused {
                Button {
                    capture.setPaused(capture.status == .recording)
                } label: {
                    Image(systemName: capture.status == .recording ? "pause.fill" : "play.fill")
                }
                .buttonStyle(.borderless)
                .help(capture.status == .recording ? "暂停记录" : "继续记录")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch capture.status {
        case .recording: return capture.trackpadAvailable ? Theme.ok : Theme.warn
        case .noPermission: return .red
        default: return Theme.rest
        }
    }
}
