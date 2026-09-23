import SwiftUI
import InputscapeKit

/// 双指横扫手势流（phase + momentumPhase 归一上报）；
/// ended 携带事件流 EMA 估算的瞬时速度（pt/s），供快甩判定
private enum ScrollGestureEvent {
    case began
    case changed(CGFloat)        // 内容方向的位移增量（点）
    case ended(velocity: CGFloat)
    case momentumBegan
    case momentumChanged(CGFloat)
    case momentumEnded
}

/// 自定义统计区间弹层：竖向单月日历 + 可键入的日期输入框。
///
/// 选期流程（三段状态机）：
/// - 第 1 次点击日历 → 选定开始日期；
/// - 第 2 次点击 → 选定结束日期（必须晚于开始日期，否则忽略）；
/// - 第 3 次点击 → 重置流程，清空选择回到开始日期的选定状态。
///
/// 日历翻页为「跟手 pager」（对齐相册切换照片的手感）：
/// - 拖拽 / 双指横扫过程中，当前月网格实时跟随手指平移，
///   相邻月份网格在侧边候场，两张"照片"连着滑；
/// - 松手按位移判定（>面板宽 1/3 完成，否则回弹），spring 动画；
/// - 双指横扫用 scrollWheel 的 phase（began/changed/ended）连续跟手；
/// - 到达边界（下个月超过当前月）时橡皮筋阻尼。
///
/// 其他：
/// - 输入框可键入 YYYY-MM-DD / 2026-9-3 / 20260913（补零、超月收敛、非法回退）；
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
    /// 翻页跟手位移：负值 = 露出下个月，正值 = 露出上个月；静止时为 0
    @State private var dragOffset: CGFloat = 0
    @State private var startText = ""
    @State private var endText = ""
    @FocusState private var focusedField: Field?
    /// 本次手势流是否已完成翻页（防动量延续导致一次轻扫翻多页）
    @State private var gestureCommitted = false
    /// 手势流结束后短暂等待动量的延迟任务
    @State private var scrollEndWorkItem: DispatchWorkItem?

    private let calendar = Calendar.current
    private let weekdaySymbols = ["日", "一", "二", "三", "四", "五", "六"]
    /// 日历网格固定 6 行高（各月 5/6 行不等，固定高度避免翻页时弹层跳动）
    private static let calendarGridHeight: CGFloat = 6 * 34 + 5 * 4
    /// 日历面板宽度 = 弹层 320 - 左右 padding 16×2（常量，供阈值判定）
    private static let panelWidth: CGFloat = 288
    /// 翻页位移阈值（面板宽 1/6 ≈ 48pt，轻快短滑即可触发）
    private static let pageTurnDistanceThreshold: CGFloat = panelWidth / 9
    /// 快甩判定：预测终点位移 ≥ 面板宽 1/4（72pt）且与位移同向
    private static let flickPredictedThreshold: CGFloat = panelWidth / 4
    /// 拖拽中途翻页：拖过面板 55% 立即翻页，不等松手
    private static let midDragCommitRatio: CGFloat = 0.55
    /// 双指路径快甩速度阈值（pt/s，事件流 EMA 估算）
    private static let scrollVelocityThreshold: CGFloat = 500

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
                HelpMarker(text: "三步选定：第 1 次点日历选开始，第 2 次选结束（需晚于开始），第 3 次点击重置重新选。也可在输入框键入 2026-09-13 或 20260913（自动补零、超月收敛到月末）；日历左右拖动或双指横扫翻月，跟手滑动。")
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

            // 日历 pager：三联网格（上一月 | 当前月 | 下一月），offset 跟手。
            // 网格是 Equatable 子视图：跟手拖动时只有 offset 变化，
            // 月份 / 选区不变 → SwiftUI 跳过网格重建，仅合成 offset 位移，
            // 保证 60–120Hz 滚动事件下跟手不掉帧。
            ZStack {
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        pagerSlot(previousMonth, width: geo.size.width)
                        MonthGridView(month: visibleMonth,
                                      startDay: startDay,
                                      endDay: endDay,
                                      onDayClick: handleDayClick)
                            .equatable()
                            .frame(width: geo.size.width)
                        pagerSlot(nextMonth, width: geo.size.width)
                    }
                    .frame(width: geo.size.width * 3, alignment: .leading)
                    .offset(x: -geo.size.width + dragOffset)
                    .highPriorityGesture(dragGesture(width: geo.size.width))
                }
            }
            .frame(height: Self.calendarGridHeight)
            .clipped()

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
        .background(ScrollSwiper { event in
            handleScrollEvent(event)
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

    // MARK: - 月份翻页（跟手 pager）

    private var previousMonth: Date? {
        calendar.date(byAdding: .month, value: -1, to: visibleMonth)
    }

    private var nextMonth: Date? {
        guard canGoNext else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: visibleMonth)
    }

    private var canGoNext: Bool {
        guard let next = calendar.date(byAdding: .month, value: 1, to: visibleMonth) else { return false }
        return next <= Self.startOfMonth(Date())
    }

    private func turnPage(to target: Date) {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            dragOffset = target > visibleMonth ? -Self.panelWidth : Self.panelWidth
        } completion: {
            // 无动画置换当前月：视觉无缝（相邻格内容与置换后一致）
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visibleMonth = target
                dragOffset = 0
            }
        }
    }

    /// 松手判定：位移 ≥ 面板宽 1/9（32pt，短滑即翻），或快甩（预测终点 ≥ 面板宽 1/4
    /// 且与位移同向）也翻页；都不满足 → 弹回原位。
    private func finishSwipe(dx: CGFloat, predictedEnd: CGFloat = 0, width: CGFloat) {
        if dx < 0, (abs(dx) >= Self.pageTurnDistanceThreshold || predictedEnd <= -Self.flickPredictedThreshold),
           let next = nextMonth {
            gestureCommitted = true
            turnPage(to: next)
        } else if dx > 0, (abs(dx) >= Self.pageTurnDistanceThreshold || predictedEnd >= Self.flickPredictedThreshold),
                  let previous = previousMonth {
            gestureCommitted = true
            turnPage(to: previous)
        } else {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragOffset = 0 }
        }
    }

    // MARK: - 双指横扫手势流处理（含动量延续）

    private func handleScrollEvent(_ event: ScrollGestureEvent) {
        switch event {
        case .began:
            scrollEndWorkItem?.cancel()
            gestureCommitted = false
            dragOffset = 0
        case .changed(let delta):
            scrollEndWorkItem?.cancel()
            applyScrollDelta(delta)
        case .ended(let velocity):
            guard !gestureCommitted else { return }
            // 快甩：松手瞬间速度达标立即翻页，不等动量
            if abs(velocity) >= Self.scrollVelocityThreshold, let target = targetFor(direction: velocity) {
                gestureCommitted = true
                turnPage(to: target)
            } else if abs(dragOffset) >= Self.pageTurnDistanceThreshold, let target = swipeTarget() {
                // 位移已达标：立即翻页
                gestureCommitted = true
                turnPage(to: target)
            } else {
                // 都不达标：短暂等待动量（轻扫惯性可以带过阈值）
                scheduleDeferredFinish()
            }
        case .momentumBegan:
            scrollEndWorkItem?.cancel()
        case .momentumChanged(let delta):
            guard !gestureCommitted else { return }
            applyScrollDelta(delta) // 动量满额延续，轻扫惯性自然带过阈值
            if let target = swipeTarget(), abs(dragOffset) >= Self.pageTurnDistanceThreshold {
                gestureCommitted = true
                turnPage(to: target)
            }
        case .momentumEnded:
            // 手势流结束：复位标志（下次手势 .began 重新判定），按位移收尾
            gestureCommitted = false
            if let target = swipeTarget(), abs(dragOffset) >= Self.pageTurnDistanceThreshold {
                gestureCommitted = true
                turnPage(to: target)
            } else {
                withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { dragOffset = 0 }
            }
        }
    }

    private func swipeTarget() -> Date? {
        dragOffset < 0 ? nextMonth : (dragOffset > 0 ? previousMonth : nil)
    }

    private func targetFor(direction: CGFloat) -> Date? {
        direction < 0 ? nextMonth : previousMonth
    }

    /// 应用横扫位移增量；边界（下月超出当前月）橡皮筋阻尼
    private func applyScrollDelta(_ delta: CGFloat) {
        var target = dragOffset + delta
        if target < -Self.panelWidth && nextMonth == nil {
            target = -Self.panelWidth + (target + Self.panelWidth) * 0.25
        }
        dragOffset = target
    }

    /// 手势流结束后短暂等待动量延续；无动量才回弹 / 翻页
    private func scheduleDeferredFinish() {
        scrollEndWorkItem?.cancel()
        let item = DispatchWorkItem {
            finishSwipe(dx: dragOffset, width: Self.panelWidth)
        }
        scrollEndWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: item)
    }

    private func dragGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                guard !gestureCommitted else { return } // 中途已翻页，忽略余量拖动
                var dx = value.translation.width
                if dx < 0 && nextMonth == nil {
                    // 已是当前月还往左拖：橡皮筋阻尼
                    dx *= 0.25
                }
                dragOffset = dx
                // 激进：拖过面板 55% 立即翻页，不等松手
                if let target = swipeTarget(), abs(dx) >= width * Self.midDragCommitRatio {
                    gestureCommitted = true
                    turnPage(to: target)
                }
            }
            .onEnded { value in
                defer { gestureCommitted = false } // 手势结束复位，下一次重新判定
                guard !gestureCommitted else { return }
                finishSwipe(dx: value.translation.width,
                            predictedEnd: value.predictedEndTranslation.width,
                            width: width)
            }
    }

    /// 侧边候场格：上一月 / 下一月不存在时留空
    private func pagerSlot(_ month: Date?, width: CGFloat) -> some View {
        Group {
            if let month {
                MonthGridView(month: month,
                              startDay: startDay,
                              endDay: endDay,
                              onDayClick: handleDayClick)
                    .equatable()
            } else {
                Color.clear
            }
        }
        .frame(width: width)
    }

    private var monthHeader: some View {
        HStack {
            Button {
                if let previous = previousMonth { turnPage(to: previous) }
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
                if let next = nextMonth { turnPage(to: next) }
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(nextMonth != nil ? Theme.navy : Theme.tertiary)
                    .frame(width: 24, height: 24)
                    .background(Circle().fill(Theme.background))
            }
            .buttonStyle(.plain)
            .disabled(nextMonth == nil)
        }
    }

    private var monthTitle: String {
        let month = calendar.component(.month, from: visibleMonth)
        let year = calendar.component(.year, from: visibleMonth)
        return "\(year)年\(month)月"
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

    /// 解析键入的日期，三种形态：
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

/// 单月日历网格（Equatable）：跟手拖动时只有 pager 的 offset 变化，
/// 月份与选区不变 → SwiftUI 通过相等性检查跳过整个网格的重建与 diff，
/// 一次横扫事件只合成一次 offset 位移，帧预算内稳定 60fps+。
/// 网格用确定性 `Grid`（非 Lazy）：滑入视口的格子不会懒加载 popping。
private struct MonthGridView: View, Equatable {
    let month: Date
    let startDay: Date?
    let endDay: Date?
    var onDayClick: (Date) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.month == rhs.month && lhs.startDay == rhs.startDay && lhs.endDay == rhs.endDay
    }

    var body: some View {
        Grid(horizontalSpacing: 0, verticalSpacing: 4) {
            ForEach(rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { day in
                        if let day {
                            dayCell(day)
                        } else {
                            Color.clear.frame(minHeight: 34)
                        }
                    }
                }
            }
        }
    }

    private var rows: [[Date?]] {
        let calendar = Calendar.current
        let daysInMonth = calendar.range(of: .day, in: .month, for: month)?.count ?? 30
        let firstWeekday = calendar.component(.weekday, from: month) // 1 = 周日
        var cells: [Date?] = Array(repeating: nil, count: firstWeekday - 1)
        for day in 0..<daysInMonth {
            cells.append(calendar.date(byAdding: .day, value: day, to: month))
        }
        while cells.count % 7 != 0 { cells.append(nil) }
        return stride(from: 0, to: cells.count, by: 7).map { Array(cells[$0..<min($0 + 7, cells.count)]) }
    }

    private func dayCell(_ date: Date) -> some View {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
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
            onDayClick(date)
        }
        .accessibilityLabel(Text(Self.isoString(date) + (marker.map { "，\($0)" } ?? "")))
        .accessibilityAddTraits(isEndpoint ? .isSelected : [])
    }

    private static func isoString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter.string(from: date)
    }
}

/// 双指横扫连续跟手：本地 scrollWheel 监听（只响应本弹层窗口），
/// 利用事件自带 phase（began/changed/ended）+ momentumPhase（动量）
/// 上报完整手势流；松手时上报事件流 EMA 估算的速度供快甩判定；
/// 动量阶段的位移增量满额驱动 pager——轻扫的惯性可以自然带过阈值。
/// deltaX 直接是内容方向的位移增量，与自然滚动设置无关。
private struct ScrollSwiper: NSViewRepresentable {
    let onEvent: (ScrollGestureEvent) -> Void

    final class CaptureView: NSView {
        var onEvent: ((ScrollGestureEvent) -> Void)?
        private var monitor: Any?
        /// 事件流瞬时速度的 EMA（pt/s），松手时上报供快甩判定
        private var velocityEMA: CGFloat = 0
        private var lastTimestamp: TimeInterval = 0

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
            guard let window else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === window else { return event }
                // 精确像素（触控板）直接用；滚轮线单位换算为点
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 12
                let delta = CGFloat(event.deltaX) * scale

                // 速度估算：EMA 平滑相邻事件的瞬时速度（点/秒）
                let dt = max(0.001, event.timestamp - lastTimestamp)
                lastTimestamp = event.timestamp
                velocityEMA = velocityEMA * 0.6 + (delta / CGFloat(dt)) * 0.4

                // 动量阶段（手指已离盘）：上报给 pager 做惯性延续判定
                if !event.momentumPhase.isEmpty {
                    switch event.momentumPhase {
                    case .began:
                        onEvent?(.momentumBegan)
                    case .changed:
                        guard delta != 0 else { return event }
                        onEvent?(.momentumChanged(delta))
                    case .ended:
                        onEvent?(.momentumEnded)
                    default:
                        break
                    }
                    return nil
                }

                // 常规手势阶段（手指在盘上）
                switch event.phase {
                case .began:
                    velocityEMA = 0
                    onEvent?(.began)
                case .changed:
                    // 不按轴向丢事件：纵向滚动 deltaX≈0 本身无位移，
                    // 丢事件反而造成跟手顿挫
                    guard delta != 0 else { return event }
                    onEvent?(.changed(delta))
                case .ended:
                    onEvent?(.ended(velocity: velocityEMA))
                default:
                    break
                }
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
        view.onEvent = onEvent
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? CaptureView)?.onEvent = onEvent
    }
}
