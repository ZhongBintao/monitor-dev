import Foundation

/// 聚合引擎：把监听层归一化后的「物理键位 ID / 操作类别」事件
/// 累加进当天的 DailyRecord，并输出任意周期的聚合快照。
///
/// 活跃输入时长模型（设计文档 §4）：连续 60 秒没有合规事件即结束
/// 当前输入段；段时长 = 段首事件到段尾事件的跨度。
public final class AggregationEngine: @unchecked Sendable {

    /// 输入段判定间隔（秒）。
    public static let sessionGap: TimeInterval = 60

    private let lock = NSLock()
    private var calendar: Calendar
    private let now: () -> Date

    private var currentDay: String
    private var record: DailyRecord
    private var sessionStart: Date?
    private var lastEventAt: Date?
    /// 已结算的历史段总秒数（跨段累计，含当日已结束的段）。
    private var closedSessionSeconds: Double = 0

    public init(calendar: Calendar = .current, now: @escaping () -> Date = Date.init) {
        self.calendar = calendar
        self.now = now
        let today = Self.dayString(for: now(), calendar: calendar)
        self.currentDay = today
        self.record = DailyRecord(date: today)
    }

    // MARK: - 事件入口（只接受物理键位 ID 与操作类别）

    /// 记一次按键。keyID 必须来自 KeyboardLayoutSpec 的物理键位 ID。
    public func ingestKey(keyID: String, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let t = date ?? now()
        rolloverIfNeeded(at: t)
        markActivity(at: t)
        record.keyCounts[keyID, default: 0] += 1
        bumpBucket(at: t, keyboard: 1, trackpad: 0)
    }

    /// 记一次组合键和弦（如 "⌘C"）。组合是 keyDown 的派生维度，
    /// 不重复计入 5 分钟桶与活跃输入段。
    public func ingestCombo(_ comboID: String, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let t = date ?? now()
        rolloverIfNeeded(at: t)
        record.comboCounts[comboID, default: 0] += 1
    }

    /// 记一次触控板操作（聚合类别）。
    public func ingestTrackpad(_ kind: TrackpadOperationKind, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let t = date ?? now()
        rolloverIfNeeded(at: t)
        markActivity(at: t)
        record.trackpadCounts[kind.rawValue, default: 0] += 1
        bumpHour(kind: kind, at: t)
        bumpBucket(at: t, keyboard: 0, trackpad: 1)
    }

    // MARK: - Force Touch 与点击压力

    /// Force Touch 触控板能力开关（设置页「设备支持 Force Touch」联动）。
    /// 关闭时不采集点击压力分档，深按（forceTouch）也不计数——开关真正生效。
    private var forceTouchEnabled = true

    public func setForceTouchEnabled(_ enabled: Bool) {
        lock.lock(); defer { lock.unlock() }
        forceTouchEnabled = enabled
    }

    public func isForceTouchEnabled() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return forceTouchEnabled
    }

    /// 记一次点击压力样本（leftMouseDown 的 kCGMouseEventPressure，0–1+）。
    /// 按 PressureTier 阈值分轻/中/深三档累计直方图并累加压力和（毫级整数）。
    /// 压力分档是点击的派生维度：不进 5 分钟桶、时段分布与活跃输入段
    /// （与组合键同样的口径），深按档样本对应的点击已计入 forceTouch 类别。
    public func ingestPressure(_ pressure: Double, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        guard forceTouchEnabled else { return }
        let t = date ?? now()
        rolloverIfNeeded(at: t)
        let tier = PressureTier.classify(pressure)
        record.pressureTierCounts[tier.rawValue, default: 0] += 1
        record.pressureSumMilli += Int((pressure * 1000).rounded())
    }

    // MARK: - 触点热力图

    /// 记一次触点（归一化坐标 0–1，x 左→右，y 上→下）。
    /// 触点位置只按 24×16 网格按日聚合计数；触点是"存在"而非"操作"：
    /// 不进 5 分钟桶、时段分布，也不延长活跃输入段。
    /// 由 MT 内部线程高频调用（~125Hz×触点数），只做格子累加。
    public func ingestTouchpoint(normalizedX: Double, normalizedY: Double, at date: Date? = nil) {
        lock.lock(); defer { lock.unlock() }
        let t = date ?? now()
        rolloverIfNeeded(at: t)
        let column = min(DailyRecord.touchGridColumns - 1, max(0, Int(normalizedX * Double(DailyRecord.touchGridColumns))))
        let row = min(DailyRecord.touchGridRows - 1, max(0, Int(normalizedY * Double(DailyRecord.touchGridRows))))
        if record.touchGrid.count != DailyRecord.touchGridCells {
            record.touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        }
        record.touchGrid[row * DailyRecord.touchGridColumns + column] += 1
    }

    // MARK: - 输入段（活跃输入时长）

    private func markActivity(at t: Date) {
        if let last = lastEventAt, t.timeIntervalSince(last) <= Self.sessionGap {
            // 同段延续。
            lastEventAt = max(last, t)
        } else {
            // 结束上一段：段时长按段首到段尾计。
            if let start = sessionStart, let last = lastEventAt {
                closedSessionSeconds += max(0, last.timeIntervalSince(start))
            }
            sessionStart = t
            lastEventAt = t
        }
    }

    /// 主动结束当前输入段（暂停、休眠、退出前调用），把未结算段写入累计。
    public func closeSession() {
        lock.lock(); defer { lock.unlock() }
        if let start = sessionStart, let last = lastEventAt {
            closedSessionSeconds += max(0, last.timeIntervalSince(start))
        }
        sessionStart = nil
        lastEventAt = nil
    }

    /// 当前已累计的活跃输入秒数（含尚未结束的当前段）。
    public func activeSecondsToday() -> Double {
        lock.lock(); defer { lock.unlock() }
        return activeSecondsLocked()
    }

    private func activeSecondsLocked() -> Double {
        var total = closedSessionSeconds
        if let start = sessionStart, let last = lastEventAt {
            total += max(0, last.timeIntervalSince(start))
        }
        return total
    }

    // MARK: - 桶

    private func bumpBucket(at t: Date, keyboard: Int, trackpad: Int) {
        let idx = TimeBucket.index(for: t, calendar: calendar)
        if let i = record.buckets.firstIndex(where: { $0.index == idx }) {
            record.buckets[i].keyboard += keyboard
            record.buckets[i].trackpad += trackpad
        } else {
            record.buckets.append(TimeBucket(index: idx, keyboard: keyboard, trackpad: trackpad))
        }
    }

    private func bumpHour(kind: TrackpadOperationKind, at t: Date) {
        let hour = calendar.component(.hour, from: t)
        var series = record.hourlyByOp[kind.rawValue] ?? Array(repeating: 0, count: 24)
        if series.count != 24 {
            series = Array(repeating: 0, count: 24)
        }
        series[hour] += 1
        record.hourlyByOp[kind.rawValue] = series
    }

    // MARK: - 跨天

    /// 若当前时刻已跨天，结算旧记录并开启新一天（返回旧记录以便持久化）。
    @discardableResult
    private func rolloverIfNeeded(at t: Date) -> DailyRecord? {
        let day = Self.dayString(for: t, calendar: calendar)
        guard day != currentDay else { return nil }
        // 结算旧日
        var old = record
        old.activeSeconds = activeSecondsLocked()
        closeSessionLocked()
        closedSessionSeconds = 0
        currentDay = day
        record = DailyRecord(date: day)
        return old
    }

    private func closeSessionLocked() {
        if let start = sessionStart, let last = lastEventAt {
            closedSessionSeconds += max(0, last.timeIntervalSince(start))
        }
        sessionStart = nil
        lastEventAt = nil
    }

    /// 拉取当天记录的副本（持久化用）。
    public func todayRecord() -> DailyRecord {
        lock.lock(); defer { lock.unlock() }
        var r = record
        r.activeSeconds = activeSecondsLocked()
        return r
    }

    /// 清空当天进行时数据（用户删除今日数据时调用）；
    /// 已落盘的历史记录不受影响。
    public func replaceWithEmptyDay() {
        lock.lock(); defer { lock.unlock() }
        record = DailyRecord(date: currentDay)
        sessionStart = nil
        lastEventAt = nil
        closedSessionSeconds = 0
    }

    /// 应用重启时回灌今天已落盘的记录，避免当日统计清零。
    public func loadToday(from store: AggregateStore) {
        lock.lock(); defer { lock.unlock() }
        if let saved = store.load(day: currentDay), saved.date == currentDay {
            record = saved
        }
    }

    /// 当前日期字符串（yyyy-MM-dd，本机时区）。
    public static func dayString(for date: Date, calendar: Calendar) -> String {
        let comps = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d",
                      comps.year ?? 0, comps.month ?? 0, comps.day ?? 0)
    }

    // MARK: - 周期快照

    /// 合并「历史落盘记录 + 今天内存中的进行时数据」输出周期快照。
    public func snapshot(scope: PeriodScope, store: AggregateStore) -> AggregateSnapshot {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let today = Self.dayString(for: t, calendar: calendar)

        var todayMerged = record
        todayMerged.activeSeconds = activeSecondsLocked()

        // 历史（不含今天）：7 天窗口 = 今天 + 前 6 天；今天窗口 = 仅今天。
        let historical = scope.dayCount <= 1
            ? []
            : store.loadRecentDays(scope.dayCount - 1, before: today)

        var keyCounts: [String: Int] = [:]
        var comboCounts: [String: Int] = [:]
        var trackpadCounts: [String: Int] = [:]
        var hourly: [String: [Int]] = [:]
        var pressureTierCounts: [String: Int] = [:]
        var pressureSumMilli = 0
        var touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        var activeSeconds = 0.0

        for day in historical {
            for (k, v) in day.keyCounts { keyCounts[k, default: 0] += v }
            for (k, v) in day.comboCounts { comboCounts[k, default: 0] += v }
            for (k, v) in day.trackpadCounts { trackpadCounts[k, default: 0] += v }
            for (k, series) in day.hourlyByOp {
                let dst = hourly[k] ?? Array(repeating: 0, count: 24)
                hourly[k] = zip(dst, series).map { $0 + $1 }
            }
            for (k, v) in day.pressureTierCounts { pressureTierCounts[k, default: 0] += v }
            pressureSumMilli += day.pressureSumMilli
            mergeTouchGrid(&touchGrid, day.touchGrid)
            activeSeconds += day.activeSeconds
        }
        for (k, v) in todayMerged.keyCounts { keyCounts[k, default: 0] += v }
        for (k, v) in todayMerged.comboCounts { comboCounts[k, default: 0] += v }
        for (k, v) in todayMerged.trackpadCounts { trackpadCounts[k, default: 0] += v }
        for (k, series) in todayMerged.hourlyByOp {
            let dst = hourly[k] ?? Array(repeating: 0, count: 24)
            hourly[k] = zip(dst, series).map { $0 + $1 }
        }
        for (k, v) in todayMerged.pressureTierCounts { pressureTierCounts[k, default: 0] += v }
        pressureSumMilli += todayMerged.pressureSumMilli
        mergeTouchGrid(&touchGrid, todayMerged.touchGrid)
        activeSeconds += todayMerged.activeSeconds

        // 桶：历史日按星期内聚合意义有限，快照桶 = 最近 dayCount 天逐桶求和。
        var bucketMap: [Int: TimeBucket] = [:]
        func absorb(_ buckets: [TimeBucket]) {
            for b in buckets {
                if var existing = bucketMap[b.index] {
                    existing.keyboard += b.keyboard
                    existing.trackpad += b.trackpad
                    bucketMap[b.index] = existing
                } else {
                    bucketMap[b.index] = b
                }
            }
        }
        for day in historical { absorb(day.buckets) }
        absorb(todayMerged.buckets)
        let mergedBuckets = bucketMap.values.sorted { $0.index < $1.index }

        var kindCounts: [TrackpadOperationKind: Int] = [:]
        for kind in TrackpadOperationKind.allCases {
            kindCounts[kind] = trackpadCounts[kind.rawValue] ?? 0
        }
        var hourlyKind: [TrackpadOperationKind: [Int]] = [:]
        for kind in TrackpadOperationKind.allCases {
            hourlyKind[kind] = hourly[kind.rawValue] ?? Array(repeating: 0, count: 24)
        }
        var pressureKindCounts: [PressureTier: Int] = [:]
        for tier in PressureTier.allCases {
            pressureKindCounts[tier] = pressureTierCounts[tier.rawValue] ?? 0
        }

        // 按日序列（旧 → 新），今天在内；零数据日不出现（保持趋势图空态语义）。
        var byDay: [String: DaySeriesPoint] = [:]
        for day in historical {
            byDay[day.date] = DaySeriesPoint(date: day.date, keyboard: day.keyTotal,
                                             trackpad: day.trackpadTotal,
                                             activeSeconds: day.activeSeconds)
        }
        byDay[todayMerged.date] = DaySeriesPoint(date: todayMerged.date,
                                                 keyboard: todayMerged.keyTotal,
                                                 trackpad: todayMerged.trackpadTotal,
                                                 activeSeconds: todayMerged.activeSeconds)
        let series: [DaySeriesPoint]
        if scope.dayCount == 1 {
            series = [byDay[today]].compactMap { $0 }
        } else {
            let window = Self.lastNDays(scope.dayCount, endingAt: t, calendar: calendar)
            series = window.compactMap { byDay[$0] }
                .filter { $0.keyboard > 0 || $0.trackpad > 0 || $0.activeSeconds > 0 }
        }

        return AggregateSnapshot(
            scope: scope,
            dayCount: scope.dayCount,
            keyPresses: keyCounts.values.reduce(0, +),
            trackpadOps: trackpadCounts.values.reduce(0, +),
            activeSeconds: activeSeconds,
            keyCounts: keyCounts,
            comboCounts: comboCounts,
            trackpadCounts: kindCounts,
            buckets: mergedBuckets,
            hourlyByOp: hourlyKind,
            daySeries: series,
            pressureTierCounts: pressureKindCounts,
            pressureSumMilli: pressureSumMilli,
            touchGrid: touchGrid
        )
    }

    /// 触点网格逐格累加（容忍长度不符的旧记录，缺省视为空网格）。
    private func mergeTouchGrid(_ target: inout [Int], _ source: [Int]) {
        guard target.count == DailyRecord.touchGridCells else { return }
        for (index, value) in source.enumerated() where index < target.count {
            target[index] += value
        }
    }

    /// 生成以结束日为准的最近 n 天日期字符串（含结束日）。
    public static func lastNDays(_ n: Int, endingAt date: Date, calendar: Calendar) -> [String] {
        var days: [String] = []
        for offset in stride(from: n - 1, through: 0, by: -1) {
            if let d = calendar.date(byAdding: .day, value: -offset, to: date) {
                days.append(dayString(for: d, calendar: calendar))
            }
        }
        return days
    }

    // MARK: - 自定义起止日期

    /// 解析 yyyy-MM-dd（按给定日历的时区）。
    public static func parseDay(_ day: String, calendar: Calendar) -> Date? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        return formatter.date(from: day)
    }

    /// 闭区间日期序列（start == end 时返回单日）。
    public static func dayRange(_ startDay: String, _ endDay: String, calendar: Calendar) -> [String] {
        guard let start = parseDay(startDay, calendar: calendar),
              let end = parseDay(endDay, calendar: calendar), start <= end else { return [] }
        var days: [String] = []
        var cursor = start
        while cursor <= end {
            days.append(dayString(for: cursor, calendar: calendar))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
            if days.count > 400 { break } // 防御：异常大范围截断
        }
        return days
    }

    /// 任意起止（闭区间）的聚合快照。开始与结束可以是同一天。
    /// 区间不含今天时，今天的进行时数据不计入。
    public func snapshot(from startDay: String, to endDay: String, store: AggregateStore) -> AggregateSnapshot {
        lock.lock(); defer { lock.unlock() }
        let t = now()
        let today = Self.dayString(for: t, calendar: calendar)
        let start = min(startDay, endDay)
        let end = max(startDay, endDay)

        var todayMerged = record
        todayMerged.activeSeconds = activeSecondsLocked()

        // 落盘区间（闭区间，今天的落盘记录由进行时数据接管）+ 今天（若在区间内）。
        var byDay: [String: DailyRecord] = [:]
        if start <= end {
            let days = store.listDays().filter { $0 >= start && $0 <= end && $0 != today }
            for day in days.compactMap({ store.load(day: $0) }) {
                byDay[day.date] = day
            }
        }
        if start <= today && today <= end {
            byDay[todayMerged.date] = todayMerged
        }

        let records = Array(byDay.values)
        var keyCounts: [String: Int] = [:]
        var comboCounts: [String: Int] = [:]
        var trackpadCounts: [String: Int] = [:]
        var hourly: [String: [Int]] = [:]
        var pressureTierCounts: [String: Int] = [:]
        var pressureSumMilli = 0
        var touchGrid = Array(repeating: 0, count: DailyRecord.touchGridCells)
        var bucketMap: [Int: TimeBucket] = [:]
        var activeSeconds = 0.0

        for day in records {
            for (k, v) in day.keyCounts { keyCounts[k, default: 0] += v }
            for (k, v) in day.comboCounts { comboCounts[k, default: 0] += v }
            for (k, v) in day.trackpadCounts { trackpadCounts[k, default: 0] += v }
            for (k, series) in day.hourlyByOp {
                let dst = hourly[k] ?? Array(repeating: 0, count: 24)
                hourly[k] = zip(dst, series).map { $0 + $1 }
            }
            for (k, v) in day.pressureTierCounts { pressureTierCounts[k, default: 0] += v }
            pressureSumMilli += day.pressureSumMilli
            mergeTouchGrid(&touchGrid, day.touchGrid)
            for b in day.buckets {
                if var existing = bucketMap[b.index] {
                    existing.keyboard += b.keyboard
                    existing.trackpad += b.trackpad
                    bucketMap[b.index] = existing
                } else {
                    bucketMap[b.index] = b
                }
            }
            activeSeconds += day.activeSeconds
        }

        var kindCounts: [TrackpadOperationKind: Int] = [:]
        for kind in TrackpadOperationKind.allCases {
            kindCounts[kind] = trackpadCounts[kind.rawValue] ?? 0
        }
        var hourlyKind: [TrackpadOperationKind: [Int]] = [:]
        for kind in TrackpadOperationKind.allCases {
            hourlyKind[kind] = hourly[kind.rawValue] ?? Array(repeating: 0, count: 24)
        }
        var pressureKindCounts: [PressureTier: Int] = [:]
        for tier in PressureTier.allCases {
            pressureKindCounts[tier] = pressureTierCounts[tier.rawValue] ?? 0
        }

        // 按日序列（旧 → 新），零数据日不出现。
        let series = Self.dayRange(start, end, calendar: calendar)
            .compactMap { byDay[$0] }
            .map { DaySeriesPoint(date: $0.date, keyboard: $0.keyTotal,
                                  trackpad: $0.trackpadTotal, activeSeconds: $0.activeSeconds) }
            .filter { $0.keyboard > 0 || $0.trackpad > 0 || $0.activeSeconds > 0 }

        return AggregateSnapshot(
            scope: .today,
            dayCount: max(1, Self.dayRange(start, end, calendar: calendar).count),
            keyPresses: keyCounts.values.reduce(0, +),
            trackpadOps: trackpadCounts.values.reduce(0, +),
            activeSeconds: activeSeconds,
            keyCounts: keyCounts,
            comboCounts: comboCounts,
            trackpadCounts: kindCounts,
            buckets: bucketMap.values.sorted { $0.index < $1.index },
            hourlyByOp: hourlyKind,
            daySeries: series,
            pressureTierCounts: pressureKindCounts,
            pressureSumMilli: pressureSumMilli,
            touchGrid: touchGrid
        )
    }
}
