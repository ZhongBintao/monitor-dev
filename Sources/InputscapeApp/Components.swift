import SwiftUI
import InputscapeKit

// MARK: - 卡片

struct Card<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                // 背景自裁剪；内容不裁剪——悬浮提示（HelpMarker）需要越出卡片边缘
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Theme.card)
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Theme.hairline, lineWidth: 1))
            )
    }
}

// MARK: - 指标卡

struct StatCard: View {
    let icon: String
    let value: String
    let unit: String
    let label: String
    var accent: Color = Theme.navy

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundColor(accent)
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 26, weight: .bold, design: .default))
                    .foregroundColor(Theme.navy)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("\(unit)\(label)")
                    .font(.system(size: 13))
                    .foregroundColor(Theme.secondary)
            }
        }
    }
}

// MARK: - 周期切换

struct PeriodPicker: View {
    @Binding var selection: PeriodScope
    var onChange: () -> Void = {}
    /// 当前是否处于自定义区间（"自定义"胶囊高亮）。
    var isCustomActive = false
    /// 提供时显示"自定义"入口，点击触发日历弹层。
    var onCustom: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(PeriodScope.allCases, id: \.self) { scope in
                Button {
                    if selection != scope {
                        selection = scope
                        onChange()
                    }
                } label: {
                    Text(scope.label)
                        .font(.system(size: 13, weight: selection == scope && !isCustomActive ? .semibold : .regular))
                        .foregroundColor(selection == scope && !isCustomActive ? Theme.keyPurple : Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(selection == scope && !isCustomActive ? Theme.keyPurpleSoft : Color.clear)
                        )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == scope && !isCustomActive ? .isSelected : [])
            }
            if let onCustom {
                Button(action: onCustom) {
                    Text("自定义")
                        .font(.system(size: 13, weight: isCustomActive ? .semibold : .regular))
                        .foregroundColor(isCustomActive ? Theme.keyPurple : Theme.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(isCustomActive ? Theme.keyPurpleSoft : Color.clear))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(isCustomActive ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Capsule().fill(Theme.background))
        .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        .fixedSize(horizontal: true, vertical: false) // 空间不足时不换行、不压缩
    }
}

// MARK: - 状态横幅（必须状态集中呈现）

struct StateBanner: View {
    let status: MonitoringStatus
    let permission: PermissionStatus
    let deviceConfirmed: Bool
    let supportsForceTouch: Bool

    var body: some View {
        ForEach(banners, id: \.text) { banner in
            HStack(spacing: 10) {
                Image(systemName: banner.icon)
                    .foregroundColor(banner.color)
                Text(banner.text)
                    .font(.system(size: 13))
                    .foregroundColor(Theme.navy)
                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(banner.background)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private struct Item {
        let icon: String
        let text: String
        let color: Color
        let background: Color
    }

    private var banners: [Item] {
        var items: [Item] = []

        if !deviceConfirmed {
            items.append(Item(icon: "questionmark.circle",
                              text: "设备未识别：尚未确认键盘模板，请完成首次引导。",
                              color: Theme.coral, background: Theme.coralSoft.opacity(0.35)))
        }
        if permission.denied && deviceConfirmed {
            items.append(Item(icon: "lock.shield",
                              text: "监听权限被拒绝或已撤销：请在系统设置 › 隐私与安全性 › 输入监听 / 辅助功能 中允许 Inputscape。",
                              color: Theme.coral, background: Theme.coralSoft.opacity(0.35)))
        }
        switch status {
        case .paused:
            items.append(Item(icon: "pause.circle",
                              text: "已手动暂停观察，恢复后数据将继续累计。",
                              color: Theme.secondary, background: Theme.background))
        case .sleeping:
            items.append(Item(icon: "moon.zzz",
                              text: "系统休眠或锁屏中，观察已自动挂起。",
                              color: Theme.secondary, background: Theme.background))
        default:
            break
        }
        if !supportsForceTouch {
            items.append(Item(icon: "hand.point.up.left",
                              text: "当前设备不支持 Force Touch，深按不计入统计。",
                              color: Theme.secondary, background: Theme.background))
        }
        return items
    }
}

// MARK: - 空状态（首次无数据）

struct EmptyStateView: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "chart.bar")
                .font(.system(size: 30))
                .foregroundColor(Theme.tertiary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(Theme.navy)
            Text(detail)
                .font(.system(size: 13))
                .foregroundColor(Theme.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(30)
    }
}

// MARK: - 悬浮提示标记（截断说明统一改为 Tooltip）

/// 卡片标题旁的 ⓘ：AppKit 原生 Tooltip（NSView.toolTip）。
/// 悬停检测、延迟、定位、消失全部由系统管理——
/// 自研悬浮窗（悬停状态机 + 独立 NSPanel）先后出现过
/// 无缘无故弹出、不消失、遮挡、被窗口裁切等边界缺陷，
/// 已整体删除；平台机制是此类功能唯一稳定实现。
struct HelpMarker: View {
    let text: String

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: 12))
            .foregroundColor(Theme.tertiary)
            .background(
                // 原生 tooltip 宿主：扩大悬停热区（图标 + 边缘余量）
                AppKitTooltip(text: text)
                    .frame(width: 18, height: 18)
            )
            .accessibilityLabel(Text("说明"))
            .accessibilityHint(Text(text))
    }
}

// MARK: - 状态点

struct StatusDot: View {
    let running: Bool

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(running ? Theme.statusGreen : Theme.tertiary)
                .frame(width: 8, height: 8)
            Text(running ? "正在观察" : "观察暂停")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - 时长格式化

func formatDuration(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    let h = total / 3600
    let m = (total % 3600) / 60
    if h > 0 { return "\(h)小时\(m)分" }
    if m > 0 { return "\(m)分钟" }
    return "\(total)秒"
}

func formatCount(_ n: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter.string(from: NSNumber(value: n)) ?? "\(n)"
}
