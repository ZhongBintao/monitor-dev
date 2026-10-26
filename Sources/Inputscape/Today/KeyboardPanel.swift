import SwiftUI
import InputscapeCore

/// 键盘热力：干净的键帽 + 悬停提示（次数、占比、按住重复）+ Top 键 / 快捷键列表。
struct KeyboardPanel: View {
    let report: DayReport

    @State private var filter: KeyFilter = .all
    @State private var hideSpaceDelete = false
    @State private var hoveredKey: String?

    private static let bigKeys: Set<String> = ["Space", "Delete"]

    var body: some View {
        let all = report.keyCounts(filter: filter)
        let values = hideSpaceDelete ? all.filter { !Self.bigKeys.contains($0.key) } : all
        let total = all.values.reduce(0, +)
        let maxCount = Double(values.values.max() ?? 0)

        Card("键盘", subtitle: total > 0 ? "\(Format.number(total)) 次" : nil) {
            HStack(spacing: Spacing.m) {
                Toggle("隐藏空格与删除", isOn: $hideSpaceDelete)
                    .toggleStyle(.checkbox).font(.caption)
                    .help("空格和删除通常远多于其他键，隐藏后其余键的差异更明显")
                if !report.keysBySource.isEmpty {
                    Picker("输入源", selection: $filter) {
                        Text("全部").tag(KeyFilter.all)
                        Text("中文").tag(KeyFilter.chinese)
                        Text("英文").tag(KeyFilter.english)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 180)
                    .help("按输入法筛选：中文 = 中文输入法开启时的按键（拼音内 Shift 切英文无法区分）")
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: Spacing.m) {
                KeyboardHeatmapView(values: values,
                                    emphasizedKeyID: hoveredKey,
                                    tooltip: { id in tooltip(for: id, counts: all, total: total) })
                HeatLegend(colors: Array(Theme.keyboardRamp.dropFirst()),
                           boundaries: HeatScale.boundaries(max: maxCount), unit: "次")
                HStack(alignment: .top, spacing: Spacing.xl) {
                    RankList(title: "最常用的键",
                             rows: topKeys(values, limit: 8),
                             total: Double(total), color: Theme.keyboard,
                             hovered: $hoveredKey)
                    RankList(title: "快捷键",
                             rows: report.shortcutCounts().sorted { $0.value > $1.value }.prefix(8)
                                .map { RankRow(id: $0.key, label: $0.key, note: nil, value: Double($0.value)) },
                             total: nil, color: Theme.keyboard.opacity(0.7),
                             hovered: .constant(nil),
                             emptyText: "按住 ⌘ 或 ⌃ 的组合才算快捷键")
                }
            }
        }
    }

    private func topKeys(_ counts: [String: Int], limit: Int) -> [RankRow] {
        counts.sorted { $0.value > $1.value }.prefix(limit).map { id, n in
            RankRow(id: id, label: Self.keyName(id), note: role(of: id), value: Double(n))
        }
    }

    private func tooltip(for id: String, counts: [String: Int], total: Int) -> String? {
        let n = counts[id] ?? 0
        var lines = ["\(Self.keyName(id)) · \(Format.number(n)) 次"]
        if total > 0, n > 0 { lines[0] += " · \(Format.percent(Double(n) / Double(total)))" }
        if let role = role(of: id) { lines.append(role) }
        if let repeats = report.repeatsByKey[id], repeats > 0 {
            lines.append("按住重复 \(Format.number(repeats)) 次（未计入）")
        }
        return lines.joined(separator: "\n")
    }

    /// 中文输入法下几个键的真实作用。
    private func role(of id: String) -> String? {
        guard filter == .chinese || (filter == .all && (report.chineseShare ?? 0) > 0.5) else { return nil }
        if id == "Space" { return "拼音：选词上屏" }
        if KeyClassifier.isCandidateDigit(id) { return "拼音：选候选词" }
        if id == "Delete" { return "含上屏前的拼音修改" }
        if id == "Return" { return "拼音：直接上屏字母" }
        return nil
    }

    static func keyName(_ id: String) -> String {
        switch id {
        case "Space": return "空格"
        case "Delete": return "删除"
        case "Return": return "回车"
        case "Tab": return "Tab"
        case "Escape": return "Esc"
        case "ShiftLeft": return "左 ⇧"
        case "ShiftRight": return "右 ⇧"
        case "CommandLeft": return "左 ⌘"
        case "CommandRight": return "右 ⌘"
        case "OptionLeft": return "左 ⌥"
        case "OptionRight": return "右 ⌥"
        case "ControlLeft": return "⌃"
        case "CapsLock": return "⇪ 中/英"
        case "Fn": return "fn"
        case "ArrowLeft": return "←"
        case "ArrowRight": return "→"
        case "ArrowUp": return "↑"
        case "ArrowDown": return "↓"
        default:
            if id.hasPrefix("Digit") { return String(id.dropFirst(5)) }
            return ComboKeyBuilder.keyLabel(for: id)
        }
    }
}

// MARK: - 排行列表

struct RankRow: Identifiable {
    let id: String
    let label: String
    let note: String?
    let value: Double
}

struct RankList: View {
    let title: String
    let rows: [RankRow]
    /// 有 total 时显示占比；否则显示次数
    let total: Double?
    let color: Color
    @Binding var hovered: String?
    var emptyText: String = "暂无"
    var valueFormatter: (Double) -> String = { Format.number(Int($0)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
            if rows.isEmpty {
                Text(emptyText).font(.caption).foregroundStyle(Theme.tertiary)
            }
            let maxValue = rows.map(\.value).max() ?? 1
            ForEach(rows) { row in
                HStack(spacing: 8) {
                    Text(row.label).font(.callout.weight(.medium)).frame(width: 64, alignment: .leading).lineLimit(1)
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color.opacity(hovered == row.id ? 1 : 0.75))
                            .frame(width: max(2, geo.size.width * row.value / maxValue))
                    }
                    .frame(height: 6)
                    Text(valueText(row)).font(.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                        .frame(width: 56, alignment: .trailing)
                }
                .help(row.note ?? "")
                .contentShape(Rectangle())
                .onHover { inside in hovered = inside ? row.id : (hovered == row.id ? nil : hovered) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func valueText(_ row: RankRow) -> String {
        if let total, total > 0 { return Format.percent(row.value / total) }
        return valueFormatter(row.value)
    }
}
