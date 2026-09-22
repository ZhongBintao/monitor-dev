import SwiftUI
import InputscapeKit

/// 自定义统计区间弹层：竖向堆叠的单月日历。
/// 交互：顶部「开始 / 结束」两个模式胶囊（显示已选日期），
/// 下方一个月历网格；选完开始自动切到结束，起止允许同一天，
/// 未来日期不可选。区间以浅紫带预览，两端为实心圆。
struct CustomRangePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode { case start, end }

    @State private var mode: Mode = .start
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var visibleMonth: Date

    private let calendar = Calendar.current
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: comps) ?? startOfDay(date)
    }

    init() {
        let today = Self.startOfDay(Date())
        _startDay = State(initialValue: today)
        _endDay = State(initialValue: today)
        _visibleMonth = State(initialValue: Self.startOfMonth(today))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自定义统计区间")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.navy)
                Spacer()
                HelpMarker(text: "先点「开始」再点日期，选完自动切到「结束」；两个日期可以相同。深紫圆点为区间两端，浅紫为区间中间。")
            }

            HStack(spacing: 8) {
                modeChip("开始", startDay, mode: .start)
                modeChip("结束", endDay, mode: .end)
                Spacer()
            }

            monthHeader

            // 星期表头（周日开头，与系统日历一致）
            HStack(spacing: 0) {
                ForEach(weekdaySymbols, id: \.self) { symbol in
                    Text(symbol)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.tertiary)
                        .frame(maxWidth: .infinity)
                }
            }

            dayGrid

            HStack(spacing: 8) {
                if model.customRange != nil {
                    Button("清除自定义", role: .destructive) {
                        model.clearCustomRange()
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
                Spacer()
                Button("取消") { dismiss() }
                    .buttonStyle(.bordered)
                Button("应用区间") {
                    model.setCustomRange(start: Self.dayString(startDay),
                                         end: Self.dayString(endDay))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.keyPurple)
            }
            .font(.system(size: 13))
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.card)
    }

    // MARK: - 模式胶囊

    private func modeChip(_ title: String, _ date: Date, mode target: Mode) -> some View {
        let active = mode == target
        return Button {
            mode = target
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(active ? Theme.keyPurple : Theme.secondary)
                Text(Self.dayString(date))
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundColor(active ? Theme.navy : Theme.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(active ? Theme.keyPurpleSoft : Theme.background))
            .overlay(Capsule().stroke(active ? Theme.keyPurple : Theme.hairline, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // MARK: - 月份导航

    private var monthHeader: some View {
        HStack {
            Button {
                moveMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.navy)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.background))
            }
            .buttonStyle(.plain)

            Spacer()
            Text(monthTitle)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.navy)
            Spacer()

            Button {
                moveMonth(1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(canGoNext ? Theme.navy : Theme.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.background))
            }
            .buttonStyle(.plain)
            .disabled(!canGoNext)
        }
    }

    private var monthTitle: String {
        let month = calendar.component(.month, from: visibleMonth)
        let year = calendar.component(.year, from: visibleMonth)
        return "\(year)年\(month)月"
    }

    private var canGoNext: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return false }
        return next <= Self.startOfMonth(Date())
    }

    private func moveMonth(_ delta: Int) {
        if let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) {
            visibleMonth = next
        }
    }

    // MARK: - 日历网格

    private var gridDays: [Date?] {
        let daysInMonth = calendar.range(of: .day, in: .month, for: visibleMonth)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: visibleMonth) // 1 = 周日
        var cells: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 0..<daysInMonth {
            cells.append(calendar.date(byAdding: .day, value: day, to: visibleMonth))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return cells
    }

    private var dayGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7),
                  spacing: 4) {
            ForEach(Array(gridDays.enumerated()), id: \.offset) { _, day in
                if let day {
                    dayCell(day)
                } else {
                    Color.clear.frame(height: 30)
                }
            }
        }
    }

    private func dayCell(_ date: Date) -> some View {
        let today = Self.startOfDay(Date())
        let isFuture = date > today
        let isStart = calendar.isDate(date, inSameDayAs: startDay)
        let isEnd = calendar.isDate(date, inSameDayAs: endDay)
        let isEndpoint = isStart || isEnd
        let inRange = !isEndpoint && date > startDay && date < endDay
        let isToday = calendar.isDateInToday(date)

        let textColor: Color = {
            if isFuture { return Theme.tertiary.opacity(0.5) }
            if isEndpoint { return .white }
            if inRange { return Theme.navy }
            return Theme.navy
        }()

        return Text("\(calendar.component(.day, from: date))")
            .font(.system(size: 12.5, weight: isEndpoint || isToday ? .semibold : .regular))
            .foregroundColor(textColor)
            .frame(maxWidth: .infinity, minHeight: 30)
            .background(
                Group {
                    if isEndpoint {
                        Circle().fill(Theme.keyPurple)
                    } else if inRange {
                        Rectangle().fill(Theme.keyPurpleSoft)
                    } else if isToday {
                        Circle().stroke(Theme.hairline, lineWidth: 1)
                    }
                }
            )
            .clipShape(isEndpoint ? AnyShape(Circle()) : AnyShape(Rectangle()))
            .contentShape(Rectangle())
            .onTapGesture {
                guard !isFuture else { return }
                select(date)
            }
            .accessibilityLabel(Text(Self.dayString(date)))
            .accessibilityAddTraits(isEndpoint ? .isSelected : [])
    }

    private func select(_ date: Date) {
        switch mode {
        case .start:
            startDay = date
            if endDay < date { endDay = date }
            mode = .end // 选完开始自动切到结束
        case .end:
            endDay = date
            if startDay > date { startDay = date }
        }
    }

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}
