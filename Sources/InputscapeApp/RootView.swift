import SwiftUI
import InputscapeKit

@main
struct InputscapeAppMain: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// 显示模式（夜览）：启动时读回上次选择并应用到 NSApp.appearance。
    @StateObject private var appearance = AppearanceManager.shared

    var body: some Scene {
        WindowGroup("Inputscape") {
            RootView()
                .environmentObject(AppModel.shared)
                .environmentObject(LiveModel.shared)
                .environmentObject(appearance)
        }
        // 隐藏标题栏里的窗口标题文字：应用已在状态栏自绘品牌行
        // （波形图标 + Inputscape），标题栏再显示产品名会形成重复标识。
        // 仅隐藏文字，标题本身保留（Dock / 调度中心仍显示 Inputscape）。
        .windowToolbarStyle(.unified(showsTitle: false))
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
        // 隐藏统一工具栏的背景与底部分隔线（titlebarSeparatorStyle 管不到它），
        // 否则标题栏区域下方会残留一条横贯全宽的 1px 线，维持"两栏"观感
        .toolbarBackground(.hidden, for: .windowToolbar)
        // 窗口 chrome 修正：标题栏透明 + 去分隔线，与状态栏合并为一栏
        .background(WindowChromeFixer().frame(width: 0, height: 0))
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
        // 侧栏与内容区的分割线：两侧底色相同（都是 Theme.background）时
        // 边界会消失，用 1pt 主题描边色补上（明暗模式各自取 hairline 档）。
        // 挂在侧栏列自身上——列宽变化或侧栏收起时分割线跟随，不会悬空。
        .overlay(alignment: .trailing) {
            Theme.hairline
                .frame(width: 1)
                .ignoresSafeArea(.container, edges: .vertical)
        }
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
