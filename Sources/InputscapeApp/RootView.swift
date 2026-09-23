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
        // 无标题栏：状态栏（品牌行）直接成为窗口第一栏，顶部无空白，
        // 也不存在工具栏安全区把内容下压的问题。
        // 拖拽能力由 WindowChromeFixer 的 isMovableByWindowBackground 补回。
        .windowStyle(.hiddenTitleBar)
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
        // 不用 NavigationSplitView：它会安装隐式 NSToolbar，即使
        // .hiddenTitleBar 也保留 ~52pt 顶部安全区把状态栏压下去；
        // 纯 HStack 分栏没有窗口 chrome 注入，状态栏贴住窗口上沿。
        HStack(spacing: 0) {
            sidebar
            // 侧栏与内容区分割线：1pt 主题描边色，全高
            Rectangle()
                .fill(Theme.hairline)
                .frame(width: 1)
            detail
        }
        .frame(minWidth: 1100, minHeight: 760)
        .background(Theme.background)
        // 窗口拖拽：无标题栏后系统不提供拖拽区，用背景拖动补回
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
            // 截图回归 / 诊断钩子：`INPUTSCAPE_PAGE=keyboard` 环境变量指定初始页面，
            // 供逐页 UI 验证与快照测试使用。必须在首帧渲染之后再切——
            // 实测在 init 阶段直接设置非默认页会导致状态栏区域不绘制
            // （布局占位保留、内容缺失），首帧后切换则无此问题。
            if let pageArg = ProcessInfo.processInfo.environment["INPUTSCAPE_PAGE"],
               let initial = AppModel.Page(rawValue: pageArg) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { model.page = initial }
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
        // 无标题栏后没有工具栏安全区，红绿灯悬浮在窗口左上角，
        // 侧栏内容需手动让出这段区域
        .safeAreaPadding(.top, 36)
        .frame(width: 200)
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
        // 背景统一由本容器绘制一次：各页面不得再自挂
        // `.background(Theme.background)`——切页重建子树时页面背景
        // 会向上扩展盖掉状态栏（实测整栏消失）。
        //
        // 忽略顶部安全区（红绿灯区 ~33pt，macOS 26 为无标题栏窗口保留），
        // 让状态栏贴住窗口上沿。HStack 结构下没有 NavigationSplitView 的
        // 隐式工具栏，切页重建子树不会触发此前的渲染丢失问题（已实测）。
        .ignoresSafeArea(.container, edges: .top)
        .background(Theme.background)
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
