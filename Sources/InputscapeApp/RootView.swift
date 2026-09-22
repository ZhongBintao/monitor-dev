import SwiftUI
import InputscapeKit

@main
struct InputscapeAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(AppModel.shared)
                .environmentObject(LiveModel.shared)
        }
        .windowResizability(.contentMinSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // 退出前落盘当日的聚合数据（仅聚合字段）。
        Task { @MainActor in
            AppModel.shared.persistNow()
        }
    }
}

// MARK: - 根视图（侧栏导航 + 状态栏）

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            // 注意：detail 不能再设 minWidth——侧栏 200 + 详情 1100 会超过窗口
            // 最小宽 1100，导致内容整体超宽、右侧与顶部被裁。
            detail
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(Theme.background)
        .sheet(isPresented: $model.onboardingVisible) {
            OnboardingView()
        }
        .onAppear {
            if !model.deviceProfile.confirmed {
                model.onboardingVisible = true
            } else {
                model.refresh()
            }
        }
    }

    private var sidebar: some View {
        List {
            Section {
                ForEach(AppModel.Page.allCases) { page in
                    row(page)
                }
            } header: {
                Text("INPUTSCAPE")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(Theme.tertiary)
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationSplitViewColumnWidth(200)
    }

    private func row(_ page: AppModel.Page) -> some View {
        Button {
            model.page = page
        } label: {
            HStack {
                Text(page.label)
                    .font(.system(size: 14, weight: model.page == page ? .semibold : .regular))
                    .foregroundColor(model.page == page ? Theme.keyPurple : Theme.navy)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(model.page == page ? Theme.keyPurpleSoft : Color.clear)
        .accessibilityAddTraits(model.page == page ? .isSelected : [])
    }

    @ViewBuilder
    private var detail: some View {
        VStack(spacing: 0) {
            statusBar
            Divider().overlay(Theme.hairline)
            Group {
                switch model.page {
                case .overview: OverviewView()
                case .keyboard: KeyboardDistributionView()
                case .trackpad: TrackpadOpsView()
                case .trends: TrendsView()
                case .live: LiveView()
                case .settings: SettingsView()
                }
            }
            .id(model.page)
        }
    }

    private var statusBar: some View {
        HStack(spacing: 14) {
            Image(systemName: "waveform.path.ecg")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(Theme.keyPurple)
            Text("Inputscape")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(Theme.navy)
            Spacer()
            if model.page == .overview {
                PeriodPicker(selection: $model.scope,
                             onChange: { model.refresh() },
                             isCustomActive: model.customRange != nil,
                             onCustom: { model.customRangeEditorVisible = true })
                .popover(isPresented: $model.customRangeEditorVisible, arrowEdge: .bottom) {
                    CustomRangePicker()
                }
            }
            StatusDot(running: model.status == .running)
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.status == .running ? "pause.fill" : "play.fill")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundColor(Theme.navy)
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(Theme.background))
                    .overlay(Circle().stroke(Theme.hairline, lineWidth: 1))
            }
            .buttonStyle(.plain)
            .disabled(!(model.deviceProfile.confirmed && model.permission.granted))
            .help(model.status == .running ? "暂停观察" : "恢复观察")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(Theme.card)
    }
}
