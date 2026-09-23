import SwiftUI
import InputscapeKit

/// 自定义统计区间弹层：竖向单月日历 + 可键入的日期输入框。
///
/// 选期流程（三段状态机，修复旧版「选错开始后无法重选」）：
/// - 第 1 次点击日历 → 选定开始日期；
/// - 第 2 次点击 → 选定结束日期（必须晚于开始日期，否则忽略）；
/// - 第 3 次点击 → 重置流程，清空选择回到开始日期的选定状态。
///
/// 其他交互：
/// - 上方「开始 / 结束」输入框一行排布，可键入 YYYY-MM-DD 或
///   20260913（8 位无分隔符）；提交 / 失焦时自动补前导零、
///   日号超月收敛到月末、非法输入回退；
/// - 日历翻页：左右拖拽 / 双指横扫 / 箭头按钮，均带滑动过渡动画；
/// - 高亮的开始 / 结束日期带文字标记；区间以浅紫带预览。
struct CustomRangePicker: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    private enum SelectionStage { case pickingStart, pickingEnd, complete }
    private enum Field { case start, end }

    @State private var stage: SelectionStage = .pickingStart
    @State private var startDay: Date?
    @State private var endDay: Date?
    @State private var visibleMonth: Date
    /// 翻页方向：新月份从哪一侧滑入
    @State private var slideEdge: Edge = .trailing
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focusedField: Field?

    private let calendar = Calendar.current
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
    /// 日历网格固定 6 行高（各月 5/6 行不等，固定高度避免翻页时弹层跳动）
    private static let calendarGridHeight: CGFloat = 6 * 34 + 5 * 4

    private static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    private static func startOfMonth(_ date: Date) -> Date {
        let comps = Calendar.current.dateComponents([.year, .month], from: date)
        return Calendar.current.date(from: comps) ?? startOfDay(date)
    }

    init() {
        let today = Self.startOfDay(Date())
        _visibleMonth = State(initialValue: Self.startOfMonth(today))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自定义统计区间")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundColor(Theme.navy)
                Spacer()
                HelpMarker(text: "三步选定：第 1 次点日历选开始，第 2 次选结束（需晚于开始），第 3 次点击重置重新选。也可在输入框键入 2026-09-13 或 20260913（自动补零、超月收敛到月末）；日历左右拖动或双指横扫翻月。")
            }

            // 开始 / 结束：一行排布的输入框，高亮框 = 当前等待填充的目标
            HStack(spacing: 10) {
                dateField(title: "开始", text: $startText, field: .start,
                          isActive: stage == .pickingStart,
                          onCommit: normalizeStart)
                dateField(title: "结束", text: $endText, field: .end,
                          isActive: stage == .pickingEnd,
                          onCommit: normalizeEnd)
                Spacer(minLength: 0)
            }

            Text(stageHint)
                .font(.system(size: 10))
                .foregroundColor(Theme.tertiary)

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

            // 日历：ZStack 承载翻页过渡（id 置换 + 方向性 move 过渡）
            ZStack {
                monthGrid
            }
            .frame(height: Self.calendarGridHeight, alignment: .top)
            .clipped()
            .highPriorityGesture(swipeGesture)

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
                    guard let start = startDay, let end = endDay, end > start else { return }
                    model.setCustomRange(start: Self.dayString(start),
                                         end: Self.dayString(end))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.keyPurple)
                .disabled(stage != .complete)
            }
            .font(.system(size: 13))
        }
        .padding(16)
        .frame(width: 320)
        .background(Theme.card)
        .background(ScrollSwiper { direction in
            shiftMonth(direction)
        }.frame(width: 0, height: 0))
        .onAppear(perform: adoptExistingRange)
        .onChange(of: focusedField) { oldField, _ in
            // 失焦时把键入内容规范化（补零 / 回退）；聚焦不改变选期阶段
            if let oldField {
                if oldField == .start { normalizeStart() } else { normalizeEnd() }
            }
        }
    }

    // MARK: - 选期阶段提示

    private var stageHint: String {
        switch stage {
        case .pickingStart:
            return "第 1 步：点击日历选择开始日期"
        case .pickingEnd:
            return "第 2 步：点击日历选择结束日期（需晚于开始日期）"
        case .complete:
            guard let start = startDay, let end = endDay else { return "" }
            return "已选 \(AppModel.chineseMonthDay(Self.dayString(start))) ～ \(AppModel.chineseMonthDay(Self.dayString(end))) · 点击日历任意日期重置重新选"
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
        guard let date = Self.parseFlexible(newValue) else { return }
        switch field {
        case .start:
            startDay = date
            if let end = endDay, end <= date {
                // 新的开始使原结束失效，回到选结束阶段
                endDay = nil
                endText = ""
                stage = .pickingEnd
            } else if endDay != nil {
                stage = .complete
            } else {
                stage = .pickingEnd
            }
        case .end:
            guard let start = startDay, date > start else { return }
            endDay = date
            stage = .complete
        }
        visibleMonth = Self.startOfMonth(date)
    }

    private func normalizeStart() {
        if let date = Self.parseFlexible(startText) {
            startDay = date
            if let end = endDay, end <= date {
                endDay = nil
                endText = ""
                stage = .pickingEnd
            } else if endDay != nil {
                stage = .complete
            } else {
                stage = .pickingEnd
            }
        }
        startText = startDay.map(Self.dayString) ?? "" // 非法输入回退；合法值补零
    }

    private func normalizeEnd() {
        if let date = Self.parseFlexible(endText) {
            if let start = startDay, date > start {
                endDay = date
                stage = .complete
            }
            // 无开始日期或未晚于开始：视为无效，文本回退
        }
        endText = endDay.map(Self.dayString) ?? ""
    }

    /// 打开弹层时回填当前生效的自定义区间（再次打开不再空白）。
    private func adoptExistingRange() {
        guard let range = model.customRange,
              let start = Self.dateFromISO(range.start),
              let end = Self.dateFromISO(range.end),
              end > start else { return }
        startDay = start
        endDay = end
        stage = .complete
        startText = range.start
        endText = range.end
        visibleMonth = Self.startOfMonth(start)
    }

    private func syncTexts() {
        startText = startDay.map(Self.dayString) ?? ""
        endText = endDay.map(Self.dayString) ?? ""
    }

    // MARK: - 选期状态机（三段式）

    private func handleDayClick(_ date: Date) {
        switch stage {
        case .pickingStart:
            startDay = date
            endDay = nil
            stage = .pickingEnd
        case .pickingEnd:
            // 结束日期必须晚于开始日期，否则忽略本次点击
            guard let start = startDay, date > start else { return }
            endDay = date
            stage = .complete
        case .complete:
            // 第三次点击：重置流程，回到开始日期的选定状态
            startDay = nil
            endDay = nil
            stage = .pickingStart
        }
        syncTexts()
    }

    // MARK: - 月份翻页（方向性滑动过渡）

    private func shiftMonth(_ delta: Int) {
        guard delta != 0 else { return }
        if delta > 0 {
            guard canGoNext else { return }
            slideEdge = .trailing // 下个月从右侧滑入
        } else {
            slideEdge = .leading // 上个月从左侧滑入
        }
        guard let next = calendar.date(byAdding: .month, value: delta, to: visibleMonth) else { return }
        withAnimation(.easeInOut(duration: 0.28)) {
            visibleMonth = next
        }
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
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
                shiftMonth(1)
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

    private var monthGrid: some View {
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
        .id(visibleMonth)
        .transition(.asymmetric(
            insertion: .move(edge: slideEdge).combined(with: .opacity),
            removal: .move(edge: slideEdge == .trailing ? .leading : .trailing).combined(with: .opacity)
        ))
    }

    private func dayCell(_ date: Date) -> some View {
        let today = Self.startOfDay(Date())
        let isFuture = date > today
        let isStart = startDay.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        let isEnd = endDay.map { calendar.isDate(date, inSameDayAs: $0) } ?? false
        let isEndpoint = isStart || isEnd
        let inRange: Bool = {
            guard let start = startDay, let end = endDay else { return false }
            return date > start && date < end
        }()
        let isToday = calendar.isDateInToday(date)

        let marker: String? = isStart ? "开始" : (isEnd ? "结束" : nil)

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
            handleDayClick(date)
        }
        .accessibilityLabel(Text(Self.dayString(date) + (marker.map { "，\($0)" } ?? "")))
        .accessibilityAddTraits(isEndpoint ? .isSelected : [])
    }

    // MARK: - 滑动切换月份（鼠标 / 触控板按住拖动）

    private var swipeGesture: some Gesture {
        DragGesture(minimumDistance: 30)
            .onEnded { value in
                let dx = value.translation.width
                if dx < -30 { shiftMonth(1) } // 左滑 → 下个月
                else if dx > 30 { shiftMonth(-1) } // 右滑 → 上个月
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

    /// 解析键入的日期，两种形态：
    /// - "2026-9-3"（可缺前导零）/ "2026-09-13"（标准带分隔符）
    /// - "20260913"（8 位无分隔符连续数字）
    /// 日号超出当月收敛到月末；无法解析返回 nil（调用方保持文本不动，提交时回退）。
    static func parseFlexible(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }
        if text.count == 8, text.allSatisfy({ ("0"..."9").contains($0) }) {
            return makeDate(year: Int(text.prefix(4)) ?? 0,
                            month: Int(text.dropFirst(4).prefix(2)) ?? 0,
                            day: Int(text.suffix(2)) ?? 0)
        }
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) else { return nil }
        return makeDate(year: year, month: month, day: day)
    }

    private static func makeDate(year: Int, month: Int, day: Int) -> Date? {
        guard (2000...2100).contains(year), (1...12).contains(month) else { return nil }
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
/// 横向滚动；deltaX 按手势流累加，累计达阈值触发一次翻页并清零——
/// 一次滑动恰好翻一页；纵向滚动即清零，其余事件原样放行。
private struct ScrollSwiper: NSViewRepresentable {
    let onSwipe: (Int) -> Void // +1 下一月，-1 上一月

    final class CaptureView: NSView {
        var onSwipe: ((Int) -> Void)?
        private var monitor: Any?
        private var accumulated: CGFloat = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window else { return event }
                guard abs(event.deltaX) >= abs(event.deltaY) else {
                    accumulated = 0
                    return event
                }
                accumulated += event.deltaX
                guard abs(accumulated) >= 12 else { return event }
                let direction = accumulated > 0 ? 1 : -1
                accumulated = 0
                onSwipe?(direction)
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
