import SwiftUI
import InputscapeKit

/// 自定义统计区间弹层：竖向单月日历 + 可键入的日期输入框。
/// 交互：
/// - 上方「开始 / 结束」输入框一行排布，可直接键入 YYYY-MM-DD
///   （提交 / 失焦时自动补前导零、日号超月收敛到月末、非法输入回退）；
///   点击输入框即切换填充目标，点日历填充当前目标，选完开始自动切到「结束」；
/// - 日历面板左右拖拽或双指横扫切换月份；
/// - 高亮的开始 / 结束日期带文字标记（起止同日显示「起止」）；
/// - 区间以浅紫带预览，两端为实心圆。
struct CustomRangePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum Mode { case start, end }
    private enum Field { case start, end }

    @State private var mode: Mode = .start
    @State private var startDay: Date
    @State private var endDay: Date
    @State private var visibleMonth: Date
    @State private var startText: String
    @State private var endText: String
    @FocusState private var focusedField: Field?

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
        _startText = State(initialValue: Self.dayString(today))
        _endText = State(initialValue: Self.dayString(today))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自定义统计区间")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.navy)
                Spacer()
                HelpMarker(text: "点日历日期填充目标框（选完开始自动切到「结束」），两个日期可以相同；也可在输入框直接键入 YYYY-MM-DD（如 2026-9-3，回车自动补零），日号超出当月会收敛到月末；日历面板左右拖动或双指横扫切换月份。")
            }

            // 开始 / 结束：一行排布的输入框，兼作填充目标指示（高亮 = 当前目标）
            HStack(spacing: 10) {
                dateField(title: "开始", text: $startText, field: .start,
                          isActive: mode == .start,
                          onCommit: normalizeStart)
                dateField(title: "结束", text: $endText, field: .end,
                          isActive: mode == .end,
                          onCommit: normalizeEnd)
                Spacer(minLength: 0)
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
                .gesture(swipeGesture)

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
                    normalizeStart()
                    normalizeEnd()
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
        .background(ScrollSwiper { delta in
            // 自然滚动方向：手指左扫 = 内容左移 = 看下个月
            if delta > 0 { moveMonth(1) } else if delta < 0 { moveMonth(-1) }
        }.frame(width: 0, height: 0))
        .onAppear(perform: adoptExistingRange)
        .onChange(of: focusedField) { oldField, newField in
            if let oldField {
                if oldField == .start { normalizeStart() } else { normalizeEnd() }
            }
            if let newField {
                mode = (newField == .start) ? .start : .end
            }
        }
    }

    // MARK: - 日期输入框（一行内完整显示，支持键入）

    private func dateField(title: String,
                           text: Binding<String>,
                           field: Field,
                           isActive: Bool,
                           onCommit: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundColor(isActive ? Theme.keyPurple : Theme.secondary)
            TextField("YYYY-MM-DD", text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .foregroundColor(Theme.navy)
                .focused($focusedField, equals: field)
                .onSubmit(onCommit)
                .onChange(of: text.wrappedValue) { _, newValue in
                    textEdited(field, newValue)
                }
                .frame(width: 112)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(isActive ? Theme.keyPurpleSoft : Theme.background)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(isActive ? Theme.keyPurple : Theme.hairline,
                                lineWidth: isActive ? 1.2 : 1)
                )
        }
        .contentShape(Rectangle())
        .onTapGesture { focusedField = field }
    }

    /// 键入过程中的实时解析：只接受完整合法的日期（日历高亮即时跟随），
    /// 不回写文本——补零等格式化留到提交 / 失焦，避免打断输入。
    private func textEdited(_ field: Field, _ newValue: String) {
        guard let date = Self.parseDateText(newValue) else { return }
        switch field {
        case .start:
            startDay = date
            if endDay < date {
                endDay = date
                endText = Self.dayString(endDay)
            }
        case .end:
            endDay = date
            if startDay > date {
                startDay = date
                startText = Self.dayString(startDay)
            }
        }
        visibleMonth = Self.startOfMonth(date)
    }

    private func normalizeStart() {
        if let date = Self.parseDateText(startText) {
            startDay = date
            if endDay < date {
                endDay = date
                endText = Self.dayString(endDay)
            }
            visibleMonth = Self.startOfMonth(date)
        }
        startText = Self.dayString(startDay) // 非法输入回退为当前有效值；合法值补零
    }

    private func normalizeEnd() {
        if let date = Self.parseDateText(endText) {
            endDay = date
            if startDay > date {
                startDay = date
                startText = Self.dayString(startDay)
            }
            visibleMonth = Self.startOfMonth(date)
        }
        endText = Self.dayString(endDay)
    }

    /// 打开弹层时回填当前生效的自定义区间（再次打开不再是空白的今天）。
    private func adoptExistingRange() {
        guard let range = model.customRange,
              let start = Self.dateFromISO(range.start),
              let end = Self.dateFromISO(range.end) else { return }
        startDay = start
        endDay = end
        startText = range.start
        endText = range.end
        visibleMonth = Self.startOfMonth(start)
        mode = .end
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
                    Color.clear.frame(height: 34)
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

        let marker: String? = {
            if isStart && isEnd { return "起止" }
            if isStart { return "开始" }
            if isEnd { return "结束" }
            return nil
        }()

        let textColor: Color = {
            if isFuture { return Theme.tertiary.opacity(0.5) }
            if isEndpoint { return .white }
            if inRange { return Theme.navy }
            return Theme.navy
        }()

        return VStack(spacing: 1) {
            Text("\(calendar.component(.day, from: date))")
                .font(.system(size: 12.5, weight: isEndpoint || isToday ? .semibold : .regular))
            if let marker {
                Text(marker)
                    .font(.system(size: 7, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
        }
        .foregroundColor(textColor)
        .frame(maxWidth: .infinity, minHeight: 34)
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
        .accessibilityLabel(Text(Self.dayString(date) + (marker.map { "，\($0)" } ?? "")))
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
        startText = Self.dayString(startDay)
        endText = Self.dayString(endDay)
    }

    // MARK: - 滑动切换月份（鼠标 / 触控板按住拖动）

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 25)
            .onEnded { value in
                let dx = value.translation.width
                if dx < -25 { moveMonth(1) } // 左滑 → 下个月
                else if dx > 25 { moveMonth(-1) } // 右滑 → 上个月
            }
    }

    // MARK: - 日期文本解析

    private static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }

    private static func dateFromISO(_ text: String) -> Date? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        return Calendar.current.date(from: comps).map { Calendar.current.startOfDay(for: $0) }
    }

    /// 解析键入的日期：接受缺前导零（"2026-9-3"）；日号超出当月收敛到月末；
    /// 无法解析返回 nil（调用方保持文本不动，提交时回退为当前有效值）。
    static func parseDateText(_ raw: String) -> Date? {
        let parts = raw.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (2000...2100).contains(year), (1...12).contains(month) else { return nil }
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = max(1, min(day, daysInMonth(year: year, month: month)))
        return Calendar.current.date(from: comps).map { Calendar.current.startOfDay(for: $0) }
    }

    private static func daysInMonth(year: Int, month: Int) -> Int {
        guard let first = Calendar.current.date(from: DateComponents(year: year, month: month, day: 1)),
              let interval = Calendar.current.dateInterval(of: .month, for: first) else { return 30 }
        return Int(interval.duration / 86400)
    }
}

/// 双指横扫切换月份：本地 scrollWheel 监听，只响应本弹层窗口内的
/// 横向滚动（|deltaX| 显著大于 |deltaY| 且超过阈值），消费该事件；
/// 其余滚动事件原样放行。
private struct ScrollSwiper: NSViewRepresentable {
    let onSwipe: (CGFloat) -> Void

    final class CaptureView: NSView {
        var onSwipe: ((CGFloat) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window else { return event }
                guard abs(event.deltaX) > abs(event.deltaY), abs(event.deltaX) > 2 else { return event }
                onSwipe?(event.deltaX)
                return nil
            }
        }

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeNSView(context: Context) -> NSView {
        let view = CaptureView()
        view.onSwipe = onSwipe
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.onSwipe = onSwipe
    }
}
