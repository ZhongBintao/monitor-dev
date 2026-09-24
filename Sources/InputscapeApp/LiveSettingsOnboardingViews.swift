import SwiftUI
import InputscapeKit

// MARK: - 实时观察

struct LiveView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            StateBanner(status: model.status,
                        permission: model.permission,
                        deviceConfirmed: model.deviceProfile.confirmed,
                        supportsForceTouch: model.deviceProfile.supportsForceTouch)
            HStack(alignment: .top, spacing: 16) {
                keyboardCard
                sidePanel.frame(width: 280)
            }
            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("让每一次触碰，即刻可见")
                .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
            Text("按下键盘或触摸触控板，查看即时反馈。")
                .font(.system(size: 14)).foregroundColor(Theme.secondary)
        }
    }

    private var keyboardCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("当前按键高亮").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "按下的物理键位即时点亮、松开立即熄灭；组合键会同时点亮所有按住的修饰键与主键。实时观察只显示物理键位与和弦，不显示字符内容；Touch ID 不产生可观察事件。")
                    Spacer()
                    StatusDot(running: model.status == .running)
                }
                KeyboardHeatmapView(values: [:],
                                    pressedKeys: live.pressedKeys,
                                    selectedKeyID: $model.selectedKeyID,
                                    reduceMotion: model.reduceMotion,
                                    minUnit: 34)
                    .aspectRatio(KeyboardHeatmapView.canvasAspectRatio, contentMode: .fit)
            }
        }
    }

    private var sidePanel: some View {
        VStack(alignment: .leading, spacing: 16) {
            heldKeysCard
            currentGestureCard
            statusCard
        }
    }

    /// 「当前按下的键」：按住的修饰键 / 普通键即时显示为徽章，松开即消失。
    private var heldKeysCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("当前按下的键").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "按住的修饰键与普通键即时显示在此处，松开即消失；修饰键与普通键同按时显示为组合（如 ⇧⌘5）。统计口径与此一致：组合 = 修饰键按住时按下的普通键，不记录时间序列。")
                    Spacer()
                }
                if live.pressedKeys.isEmpty {
                    Text("按任意键…")
                        .font(.system(size: 13))
                        .foregroundColor(Theme.tertiary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 6)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(live.heldChips().enumerated()), id: \.offset) { _, chip in
                                Text(chip)
                                    .font(.system(size: 17, weight: .bold, design: .rounded))
                                    .foregroundColor(.white)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 7)
                                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Theme.keyPurple))
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(model.reduceMotion ? nil : .linear(duration: 0.05), value: live.pressedKeys)
        }
    }

    private var currentGestureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("最近触控操作").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                if live.state.recentTrackpad.isEmpty {
                    Text("尚无触控操作").font(.system(size: 13)).foregroundColor(Theme.secondary)
                } else {
                    ForEach(live.state.recentTrackpad.prefix(5)) { event in
                        HStack {
                            Image(systemName: iconName(for: event.kind))
                                .foregroundColor(Theme.coral)
                                .frame(width: 18)
                            Text(event.kind.label)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.navy)
                            Spacer()
                            Text(event.at.formatted(date: .omitted, time: .standard))
                                .font(.system(size: 11))
                                .foregroundColor(Theme.tertiary)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var statusCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("监听状态").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "空闲超过 60 秒将结束当前输入段；实时状态仅保存在内存中，退出即丢弃。")
                }
                HStack {
                    Text("观察状态")
                        .font(.system(size: 13)).foregroundColor(Theme.secondary)
                    Spacer()
                    Text(model.status.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(model.status == .running ? Theme.statusGreen : Theme.coral)
                }
                HStack {
                    Text("空闲时长")
                        .font(.system(size: 13)).foregroundColor(Theme.secondary)
                    Spacer()
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(live.idleSeconds(now: context.date)) 秒")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(Theme.navy)
                            .monospacedDigit()
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }


    private func iconName(for kind: TrackpadOperationKind) -> String {
        switch kind {
        case .click: return "cursorarrow.click"
        case .scrollUp: return "arrow.up"
        case .scrollDown: return "arrow.down"
        case .smartZoom: return "plus.viewfinder"
        case .swipe: return "hand.draw"
        case .forceTouch: return "hand.point.up.left.fill"
        case .zoom: return "plus.magnifyingglass"
        }
    }
}

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var appearance: AppearanceManager
    @State private var confirmDeleteToday = false
    @State private var confirmDeleteAll = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                permissionCard
                deviceCard
                appearanceCard
                dataCard
            }
            .padding(20)
        }
        .confirmationDialog("删除今天的数据？", isPresented: $confirmDeleteToday, titleVisibility: .visible) {
            Button("删除今天的数据", role: .destructive) { model.deleteTodayData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除今天累计的按键数、触控操作数与活跃时长。此操作不可撤销。")
        }
        .confirmationDialog("删除全部本地数据？", isPresented: $confirmDeleteAll, titleVisibility: .visible) {
            Button("删除全部数据", role: .destructive) { model.deleteAllData() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除本机全部历史聚合统计（按键计数、触控操作计数、活跃时长与时段分布）。此操作不可撤销。")
        }
    }

    private var header: some View {
        Text("设置")
            .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
    }

    private var permissionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("权限检测").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                permissionRow(title: "输入监听（Input Monitoring）",
                              granted: model.permission.listenEvent)
                permissionRow(title: "辅助功能（Accessibility）",
                              granted: model.permission.accessibility)
                HStack {
                    Button("申请授权") { model.requestPermission() }
                        .buttonStyle(.bordered)
                    Button("重新检测") { model.refreshPermission() }
                        .buttonStyle(.bordered)
                    Spacer()
                }
                Text("路径：系统设置 › 隐私与安全性 › 输入监听 / 辅助功能。权限被撤销后，状态会显示在页面顶部横幅中。")
                    .font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
        }
    }

    private func permissionRow(title: String, granted: Bool) -> some View {
        HStack {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle")
                .foregroundColor(granted ? Theme.statusGreen : Theme.coral)
            Text(title).font(.system(size: 13)).foregroundColor(Theme.navy)
            Spacer()
            Text(granted ? "正常" : "未授权")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(granted ? Theme.statusGreen : Theme.coral)
        }
    }

    private var deviceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("设备模板").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                Picker("键盘模板", selection: Binding(
                    get: { model.deviceProfile.keyboardTemplate },
                    set: { model.setTemplate($0) }
                )) {
                    ForEach(KeyboardTemplate.allCases, id: \.self) { template in
                        Text(template.label).tag(template)
                    }
                }
                .pickerStyle(.radioGroup)
                .disabled(true) // 首版固定 US ANSI；切换模板的设备识别在后续版本开放
                Toggle("设备支持 Force Touch", isOn: Binding(
                    get: { model.deviceProfile.supportsForceTouch },
                    set: { model.setForceTouchSupport($0) }
                ))
                Toggle("实验性：触点热力图", isOn: Binding(
                    get: { model.touchHeatmapEnabled },
                    set: { model.setTouchHeatmapEnabled($0) }
                ))
                Text("触点热力图读取系统触控板多点触控数据，把触点位置按 24×16 网格按日聚合计数（不保存轨迹、原始触点流或屏幕坐标）；设备不支持时无数据。首版基准为 MacBook Pro 14/16 英寸 US ANSI 键盘；ISO、JIS 与 Magic Keyboard 模板将在后续版本提供。")
                    .font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
        }
    }

    private var appearanceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("外观").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)

                // 显示模式（夜览）：开启 / 关闭 / 跟随系统；选择即时生效并持久化。
                VStack(alignment: .leading, spacing: 8) {
                    Text("显示模式")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.secondary)
                    Picker("显示模式", selection: Binding(
                        get: { appearance.mode },
                        set: { appearance.setMode($0) }
                    )) {
                        ForEach(AppearanceMode.allCases, id: \.self) { mode in
                            Text(mode.label).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 400)
                    Text(appearanceFootnote)
                        .font(.system(size: 11))
                        .foregroundColor(Theme.tertiary)
                }

                Toggle("减少动效（关闭实时高亮脉冲等动画）", isOn: Binding(
                    get: { model.reduceMotion },
                    set: { model.setReduceMotion($0) }
                ))
                Text("界面遵循系统高对比度与辅助功能设置；键盘热力图同时提供数字与文字说明，不仅依赖颜色。")
                    .font(.system(size: 11)).foregroundColor(Theme.tertiary)
            }
        }
    }

    /// 随所选模式给出即时反馈；跟随系统档同步提示系统当前档位。
    private var appearanceFootnote: String {
        switch appearance.mode {
        case .dark:
            return "已开启夜览：深色配色，夜间使用更柔和。切换对所有页面即时生效。"
        case .light:
            return "已关闭夜览：浅色配色。切换对所有页面即时生效。"
        case .system:
            return "跟随系统深色模式自动切换，系统切换时应用同步变化（当前系统为\(appearance.systemIsDark ? "深色" : "浅色")）。"
        }
    }

    private var dataCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("数据与隐私").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                VStack(alignment: .leading, spacing: 6) {
                    bullet("仅保存本地聚合统计：每日按键数、触控操作数、活跃输入时长、5 分钟桶与键位计数。")
                    bullet("点击压力仅按轻/中/深三档计数并保留平均压力，不保存压力原始值或轨迹。")
                    bullet("触点热力图仅保存 24×16 网格触碰计数，不保存轨迹、原始触点流或屏幕坐标。")
                    bullet("不记录文字内容、按键序列、应用名称、屏幕坐标或原始事件。")
                    bullet("不提供云同步、导出或账号体系；历史数据持续保留在本机。")
                    bullet("实时观察状态仅保存在内存中，退出即丢弃。")
                    bullet("活跃输入时长按本机时区计算；连续 60 秒无事件即结束当前输入段。")
                }
                HStack {
                    Button("删除今日数据…") { confirmDeleteToday = true }
                        .buttonStyle(.bordered)
                    Button("删除全部数据…", role: .destructive) { confirmDeleteAll = true }
                        .buttonStyle(.bordered)
                    Spacer()
                }
            }
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.tertiary).frame(width: 4, height: 4).padding(.top, 5)
            Text(text).font(.system(size: 12)).foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - 首次引导

struct OnboardingView: View {
    @EnvironmentObject var model: AppModel
    @State private var step = 0
    @State private var forceTouch = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                ForEach(0..<3) { i in
                    Capsule()
                        .fill(i <= step ? Theme.keyPurple : Theme.hairline)
                        .frame(height: 4)
                }
            }
            .padding(.bottom, 24)

            switch step {
            case 0: privacyStep
            case 1: permissionStep
            default: deviceStep
            }
        }
        .padding(30)
        .frame(width: 560, height: 520)
        .background(Theme.card)
    }

    private var stepTitle: some View {
        Group {
            switch step {
            case 0: Text("开始之前，先说清楚边界").font(.system(size: 22, weight: .bold))
            case 1: Text("为什么需要权限").font(.system(size: 22, weight: .bold))
            default: Text("确认你的键盘").font(.system(size: 22, weight: .bold))
            }
        }
        .foregroundColor(Theme.navy)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle
            Text("Inputscape 是一个本地输入习惯分析工具。观察开始后，它只会保存聚合统计：")
                .font(.system(size: 14)).foregroundColor(Theme.secondary)
            VStack(alignment: .leading, spacing: 8) {
                row(icon: "checkmark.circle.fill", color: Theme.statusGreen,
                    text: "每日按键数、触控操作数、活跃输入时长")
                row(icon: "checkmark.circle.fill", color: Theme.statusGreen,
                    text: "按物理键位 ID 聚合的频率、5 分钟活动分布")
                row(icon: "xmark.circle.fill", color: Theme.coral,
                    text: "不记录文字内容与按键序列")
                row(icon: "xmark.circle.fill", color: Theme.coral,
                    text: "不记录应用名称、屏幕坐标或原始事件")
                row(icon: "xmark.circle.fill", color: Theme.coral,
                    text: "不提供云同步、导出或账号体系")
            }
            Spacer()
            nextButton("继续") { step = 1 }
        }
    }

    private var permissionStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle
            Text("要观察按键与触控板操作，macOS 要求两项系统权限：")
                .font(.system(size: 14)).foregroundColor(Theme.secondary)
            VStack(alignment: .leading, spacing: 10) {
                permissionLine(title: "输入监听（Input Monitoring）",
                               detail: "用于统计物理键位按键次数（不含字符）",
                               granted: model.permission.listenEvent)
                permissionLine(title: "辅助功能（Accessibility）",
                               detail: "用于统计触控板点击、滚动与手势",
                               granted: model.permission.accessibility)
            }
            if !model.permission.granted {
                Button("申请授权") { model.requestPermission() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            Text("授权后可随时在系统设置中撤销；撤销后应用会明确提示并停止观察。")
                .font(.system(size: 11)).foregroundColor(Theme.tertiary)
            Spacer()
            HStack {
                Button("上一步") { step = 0 }.buttonStyle(.bordered)
                Spacer()
                nextButton(model.permission.granted ? "继续" : "稍后授权，继续") { step = 2 }
            }
        }
    }

    private func permissionLine(title: String, detail: String, granted: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundColor(granted ? Theme.statusGreen : Theme.tertiary)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 14, weight: .medium)).foregroundColor(Theme.navy)
                Text(detail).font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.background))
    }

    private var deviceStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            stepTitle
            Text("统计绑定物理键位。请确认你的实际键盘模板，确保键位一一对应：")
                .font(.system(size: 14)).foregroundColor(Theme.secondary)
            Picker("键盘模板", selection: Binding(
                get: { KeyboardTemplate.macbookProUSANSI },
                set: { _ in }
            )) {
                ForEach(KeyboardTemplate.allCases, id: \.self) { template in
                    Text(template.label).tag(template)
                }
            }
            .pickerStyle(.radioGroup)
            .disabled(true)
            Toggle("这台设备支持 Force Touch（触控板深按）", isOn: $forceTouch)
            Spacer()
            HStack {
                Button("上一步") { step = 1 }.buttonStyle(.bordered)
                Spacer()
                nextButton("确认并开始观察") {
                    model.completeOnboarding(template: .macbookProUSANSI,
                                             supportsForceTouch: forceTouch)
                }
            }
        }
    }

    private func row(icon: String, color: Color, text: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color)
            Text(text).font(.system(size: 13)).foregroundColor(Theme.navy)
            Spacer()
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.background))
    }

    private func nextButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(Theme.keyPurple)
    }
}
