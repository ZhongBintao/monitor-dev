import Foundation
import AppKit
import Combine
import InputscapeKit

/// 监听与运行状态（覆盖设计文档 §6 必须状态）。
public enum MonitoringStatus: Equatable, Sendable {
    case notOnboarded      // 尚未完成首次引导
    case permissionDenied  // 权限被拒绝或撤销
    case paused            // 手动暂停
    case sleeping          // 系统锁屏或休眠
    case running           // 正在观察

    public var label: String {
        switch self {
        case .notOnboarded: return "待引导"
        case .permissionDenied: return "权限不足"
        case .paused: return "已暂停"
        case .sleeping: return "已休眠"
        case .running: return "正在观察"
        }
    }
}

/// 自定义统计区间（起止可同一天）。
public struct CustomRange: Equatable, Sendable {
    public var start: String
    public var end: String

    public init(start: String, end: String) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
}

/// 应用主模型：单向数据流。
/// 监听层 → 聚合引擎 → 快照 → 视图；视图只发起动作，不直接改数据。
/// 注意：高频事件（每次按键）只更新 LiveModel 与引擎计数，
/// 不触发本模型的 objectWillChange，避免全树重算——
/// 这是此前侧栏 / 页面交互迟缓的主要根因。
@MainActor
public final class AppModel: ObservableObject {

    /// 主模型单例（M5 重写时曾误删，编译期已被 RootView 抓住）。
    public static let shared = AppModel()

    // 导航与选择
    @Published public var page: Page = .overview
    @Published public var scope: PeriodScope = .today
    @Published public var selectedKeyID: String?
    @Published public var selectedTrendDay: String?
    @Published public var onboardingVisible = false
    @Published public private(set) var customRange: CustomRange?
    @Published public var customRangeEditorVisible = false

    // 状态（低频变化）
    @Published public private(set) var status: MonitoringStatus = .notOnboarded
    @Published public private(set) var permission: PermissionStatus = .unknown
    @Published public private(set) var deviceProfile: DeviceProfile
    @Published public private(set) var reduceMotion = false
    @Published public private(set) var snapshot: AggregateSnapshot
    /// 按压校准结果与双模式开关（UserDefaults 持久化）。
    @Published public private(set) var pressureCalibration = PressureCalibrationStore()
    /// 进行中的校准会话（测试与校准 sheet 打开期间非 nil）。
    @Published public private(set) var activeCalibrationSession: PressureCalibrationSession?

    public let store: AggregateStore
    public let engine: AggregationEngine
    private var monitor: EventMonitor?
    private var saveTask: Task<Void, Never>?
    private var idleSettleTimer: Timer?
    private var workspaceObservers: [NSObjectProtocol] = []

    public enum Page: String, CaseIterable, Identifiable {
        case overview, keyboard, trackpad, trends, live, settings
        public var id: String { rawValue }

        public var label: String {
            switch self {
            case .overview: return "总览"
            case .keyboard: return "键盘分布"
            case .trackpad: return "触控板操作"
            case .trends: return "使用趋势"
            case .live: return "实时观察"
            case .settings: return "设置"
            }
        }

        /// 侧栏导航图标（SF Symbols，简洁线性风格）
        public var icon: String {
            switch self {
            case .overview: return "square.grid.2x2"
            case .keyboard: return "keyboard"
            case .trackpad: return "hand.draw"
            case .trends: return "chart.line.uptrend.xyaxis"
            case .live: return "eye"
            case .settings: return "gearshape"
            }
        }
    }

    public init(store: AggregateStore = JSONDayStore(directory: JSONDayStore.defaultDirectory()),
                deviceProfile: DeviceProfile? = nil) {
        self.store = store
        self.engine = AggregationEngine()
        let saved = deviceProfile ?? Self.loadDeviceProfile()
        self.deviceProfile = saved
        self.status = saved.confirmed ? .permissionDenied : .notOnboarded
        self.reduceMotion = UserDefaults.standard.bool(forKey: "Inputscape.ReduceMotion")
        self.snapshot = .empty(.today)
        // 重启场景：回灌今天已落盘的记录，避免当日统计清零。
        engine.loadToday(from: store)
        // Force Touch 开关联动引擎采集（关闭时不采压力分档、不计深按）。
        engine.setForceTouchEnabled(saved.supportsForceTouch)
        // 按压校准：读回持久化的分界阈值与双模式开关。
        pressureCalibration = PressureCalibrationStore.load()
        engine.setPressureThreshold(effectivePressureThreshold)
        refresh()
        // 已确认过设备且权限齐备（应用重启场景）：立即恢复监听，
        // 否则 UI 显示"正在观察"但实际没有任何监听器在跑。
        startMonitoringIfAllowed()
    }

    // MARK: - 引导与设备

    public func completeOnboarding(template: KeyboardTemplate, supportsForceTouch: Bool) {
        deviceProfile = DeviceProfile(keyboardTemplate: template,
                                      confirmed: true,
                                      supportsForceTouch: supportsForceTouch)
        engine.setForceTouchEnabled(supportsForceTouch)
        saveDeviceProfile()
        onboardingVisible = false
        refreshPermission()
        // 明确落状态：权限齐备 → running；否则 → permissionDenied。
        status = permission.granted ? .running : .permissionDenied
        startMonitoringIfAllowed()
    }

    public func setTemplate(_ template: KeyboardTemplate) {
        deviceProfile.keyboardTemplate = template
        saveDeviceProfile()
    }

    public func setForceTouchSupport(_ supported: Bool) {
        deviceProfile.supportsForceTouch = supported
        engine.setForceTouchEnabled(supported)
        saveDeviceProfile()
    }

    private static func loadDeviceProfile() -> DeviceProfile {
        guard let data = UserDefaults.standard.data(forKey: "Inputscape.DeviceProfile"),
              let profile = try? JSONDecoder().decode(DeviceProfile.self, from: data) else {
            return DeviceProfile()
        }
        return profile
    }

    private func saveDeviceProfile() {
        if let data = try? JSONEncoder().encode(deviceProfile) {
            UserDefaults.standard.set(data, forKey: "Inputscape.DeviceProfile")
        }
    }

    // MARK: - 权限与监听

    public func refreshPermission() {
        permission = PermissionCenter.currentStatus()
        if status == .permissionDenied || status == .running {
            status = permission.granted ? .running : .permissionDenied
        }
    }

    public func requestPermission() {
        permission = PermissionCenter.requestAccess()
        if permission.granted && status != .notOnboarded {
            status = .running
        }
        startMonitoringIfAllowed()
    }

    public func togglePause() {
        switch status {
        case .running:
            status = .paused
            engine.closeSession()
            monitor?.stop()
            LiveModel.shared.clearPressed()
            updateTouchMonitor()
        case .paused:
            status = permission.granted ? .running : .permissionDenied
            startMonitoringIfAllowed()
        default:
            break
        }
    }

    /// 完成引导且权限齐备后才开始观察（已在运行则不重复启动）。
    /// 每次重新构建（ad-hoc 重签名）后 TCC 授权会被系统重置，
    /// 因此启动时若已引导过但权限缺失，自动再弹一次系统授权申请。
    private func startMonitoringIfAllowed() {
        guard deviceProfile.confirmed else { return }
        if !permission.granted {
            permission = PermissionCenter.requestAccess()
            status = permission.granted ? .running : .permissionDenied
        }
        guard permission.granted, status == .running else { return }
        if monitor?.isRunning == true { return }
        startMonitor()
        startIdleSettleTimer()
        observeWorkspace()
        updateTouchMonitor()
        startDataRefreshTimer()
    }

    private func startMonitor() {
        let engine = self.engine
        // 校准模式（用户开启且已校准）：点击重/轻改用 MTTouch 近窗接触压力
        // 对照校准阈值；系统默认模式不注入 override，走系统压力档权威口径。
        let calibrationThreshold = pressureCalibration.isActive ? pressureCalibration.threshold : nil
        let clickOverride: (@Sendable () -> Bool?)? = calibrationThreshold.map { threshold in
            { TouchpointMonitor.recentMaxContactPressure().map { $0 >= threshold } }
        }
        // 触控板操作通用管道：聚合 + 实时流 + 防抖落盘。
        let track: @Sendable (TrackpadOperationKind) -> Void = { kind in
            engine.ingestTrackpad(kind)
            Task { @MainActor in
                LiveModel.shared.noteTrackpad(kind, inProgress: false)
                AppModel.shared.scheduleSave()
            }
        }
        let handlers = EventMonitor.Handlers(
            onKey: { keyID in
                engine.ingestKey(keyID: keyID)
                Task { @MainActor in
                    LiveModel.shared.noteKey(keyID: keyID)
                    AppModel.shared.scheduleSave()
                }
            },
            onCombo: { comboID, _ in
                engine.ingestCombo(comboID)
                Task { @MainActor in
                    LiveModel.shared.noteCombo(comboID)
                }
            },
            onKeyUp: { keyID in
                Task { @MainActor in
                    LiveModel.shared.noteKeyUp(keyID: keyID)
                }
            },
            onScroll: { deltaY in
                // 上下滑识别用「手指方向语义」：标签跟随手指物理方向。
                // Kit 传来的 deltaY 符号描述内容移动方向（>0 = 内容下移）；
                // 自然滚动开启时内容跟随手指（手指下 = deltaY>0），关闭时相反。
                let natural = UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool ?? true
                let fingersDown = natural ? deltaY > 0 : deltaY < 0
                track(fingersDown ? .scrollDown : .scrollUp)
            },
            onClick: {
                track(.click)
            },
            onForceTouch: {
                // 设备不支持重按时开关真正生效：不计数、不进实时流。
                guard engine.isForceTouchEnabled() else { return }
                track(.forceTouch)
            },
            onSmartZoom: {
                track(.smartZoom)
            },
            onSwipe: {
                track(.swipe)
            },
            onPressureStage: { stage, pressure in
                Task { @MainActor in
                    LiveModel.shared.notePressureStage(stage, pressure: pressure)
                    AppModel.shared.activeCalibrationSession?.recordStage(stage)
                }
            },
            clickForceOverride: clickOverride
        )
        let monitor = EventMonitor(handlers: handlers)
        let started = monitor.start()
        self.monitor = monitor
        if !started {
            status = .permissionDenied
        }
    }

    // MARK: - 输入段结算（不触发任何 UI 失效）

    /// 空闲超过输入段间隔（60 秒）即结算当前输入段。
    /// 此定时器只调引擎，不 objectWillChange；实时页的空闲秒数
    /// 由 LiveView 里的 TimelineView 自行每秒刷新。
    /// 结算后顺带落盘：触点热力数据没有事件级 scheduleSave 触发
    /// （MT 回调线程高频，不进 UI/保存热路径），最多丢一个节拍的数据。
    private func startIdleSettleTimer() {
        LiveModel.shared.markObservationStarted()
        idleSettleTimer?.invalidate()
        idleSettleTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if LiveModel.shared.idleSeconds() > Int(AggregationEngine.sessionGap) {
                    self.engine.closeSession()
                }
                LiveModel.shared.pruneStaleKeys()
                self.persistNow()
            }
        }
    }

    // MARK: - 休眠 / 锁屏

    private func observeWorkspace() {
        guard workspaceObservers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        let sleep = center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.status = self.status == .paused ? .paused : .sleeping
                self.engine.closeSession()
                LiveModel.shared.clearPressed()
                self.persistNow()
            }
        }
        let wake = center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.status == .sleeping {
                    self.status = .running
                }
            }
        }
        workspaceObservers = [sleep, wake]
    }

    // MARK: - 数据刷新与持久化

    public func setScope(_ scope: PeriodScope) {
        customRange = nil
        self.scope = scope
        refresh()
    }

    /// 应用自定义区间（允许起止同一天；传入顺序无关）。
    public func setCustomRange(start: String, end: String) {
        customRange = CustomRange(start: start, end: end)
        refresh()
    }

    public func clearCustomRange() {
        customRange = nil
        refresh()
    }

    /// 顶栏 / 标题用的时段描述。自定义区间一律用「M月D日」中文格式，
    /// 跨年时补年份（如「2025年12月28日 ～ 2026年1月5日」）。
    public var rangeLabel: String {
        if let c = customRange {
            if c.start.prefix(4) != c.end.prefix(4) {
                return "\(Self.chineseDate(c.start)) ～ \(Self.chineseDate(c.end))"
            }
            return c.start == c.end
                ? Self.chineseMonthDay(c.start)
                : "\(Self.chineseMonthDay(c.start)) ～ \(Self.chineseMonthDay(c.end))"
        }
        return scope.label
    }

    public static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return parts.suffix(2).joined(separator: "-")
    }

    /// "2025-06-09" → "6月9日"（月 / 日去前导零）
    public static func chineseMonthDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let month = Int(parts[1]), let dayNum = Int(parts[2]) else {
            return day
        }
        return "\(month)月\(dayNum)日"
    }

    /// "2025-06-09" → "2025年6月9日"（跨年区间展示用）
    public static func chineseDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let year = Int(parts[0]) else { return day }
        return "\(year)年" + chineseMonthDay(day)
    }

    public func refresh() {
        refreshPermission()
        if let c = customRange {
            snapshot = engine.snapshot(from: c.start, to: c.end, store: store)
        } else {
            snapshot = engine.snapshot(scope: scope, store: store)
        }
    }

    /// 趋势页专用：独立于全局周期的按日快照。
    public func snapshotForTrends(dayCount: Int) -> AggregateSnapshot {
        engine.snapshot(scope: dayCount >= 30 ? .last30Days : .last7Days, store: store)
    }

    /// 防抖落盘：3 秒内无新事件才写盘。
    public func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, let self else { return }
            self.persistNow()
        }
    }

    public func persistNow() {
        let record = engine.todayRecord()
        try? store.save(record)
    }

    // MARK: - 删除数据

    public func deleteTodayData() {
        let today = engine.todayRecord().date
        try? store.deleteDay(today)
        engine.closeSession()
        engine.replaceWithEmptyDay()
        refresh()
    }

    public func deleteAllData() {
        try? store.deleteAll()
        engine.closeSession()
        engine.replaceWithEmptyDay()
        refresh()
    }

    /// 减少动效
    public func setReduceMotion(_ value: Bool) {
        reduceMotion = value
        UserDefaults.standard.set(value, forKey: "Inputscape.ReduceMotion")
    }

    // MARK: - 触点热力图

    /// 触点监听生命周期与观察状态联动：仅「已确认设备 + 权限齐备 +
    /// 正在观察」时运行；暂停 / 撤销权限即停止。
    private func updateTouchMonitor() {
        let shouldRun = deviceProfile.confirmed
            && permission.granted
            && status == .running
        if shouldRun {
            let engine = self.engine
            TouchpointMonitor.shared.start { frame in
                // 热力网格 + 按压强度直方图：逐接触手指聚合
                // （手掌已被 monitor 过滤；MT 线程直接聚合，无 UI 路径）。
                for sample in frame.touches {
                    engine.ingestTouchpoint(normalizedX: sample.x, normalizedY: sample.y)
                    engine.ingestTouchPressure(sample.pressure)
                }
                // 实时触控板（帧全量替换缓存，30Hz 合并发布）+
                // 校准会话采样（激活时把接触压力转发给会话）。
                Task { @MainActor in
                    LiveModel.shared.noteTouchFrame(frame)
                    AppModel.shared.calibrationDidReceiveTouchPressures(frame.touches.map(\.pressure))
                }
            }
            LiveModel.shared.startTouchPulse()
        } else {
            TouchpointMonitor.shared.stop()
            LiveModel.shared.stopTouchPulse()
        }
    }

    // MARK: - 按压测试与校准

    /// 打开测试与校准 sheet 时创建会话并进入轻按采集阶段。
    public func startCalibration() {
        let session = PressureCalibrationSession()
        session.beginLightCollection()
        activeCalibrationSession = session
    }

    /// 校准进入重按采集阶段（UI 引导第二步）。
    public func advanceCalibrationToHeavy() {
        activeCalibrationSession?.beginHeavyCollection()
    }

    /// 结束采集并计算结果。成功时持久化学到的分界、自动开启校准判定，
    /// 并重建监听（点击 override 随新阈值生效）；失败时保留默认。
    @discardableResult
    public func finishCalibration() -> PressureCalibrationSession.Result? {
        guard let session = activeCalibrationSession else { return nil }
        let result = session.compute()
        activeCalibrationSession = nil
        if result.isSuccess {
            pressureCalibration.threshold = result.threshold
            pressureCalibration.calibratedAt = Date()
            pressureCalibration.useCalibration = true
            pressureCalibration.save()
            engine.setPressureThreshold(result.threshold)
            rebuildMonitorIfRunning()
        }
        return result
    }

    public func cancelCalibration() {
        activeCalibrationSession = nil
    }

    /// 双模式开关：开启后点击重/轻判定改用校准阈值口径（轻/重分档同步）。
    public func setUseCalibratedPressure(_ enabled: Bool) {
        pressureCalibration.useCalibration = enabled
        pressureCalibration.save()
        engine.setPressureThreshold(effectivePressureThreshold)
        rebuildMonitorIfRunning()
    }

    /// 清除校准（恢复默认阈值与系统判定）。
    public func clearPressureCalibration() {
        pressureCalibration.clear()
        pressureCalibration.save()
        engine.setPressureThreshold(PressureTier.heavyThreshold)
        rebuildMonitorIfRunning()
    }

    /// 实际生效的轻/重分界：校准激活用学习值，否则系统默认 1.0。
    private var effectivePressureThreshold: Double {
        pressureCalibration.isActive
            ? (pressureCalibration.threshold ?? PressureTier.heavyThreshold)
            : PressureTier.heavyThreshold
    }

    /// 校准会话接收触点帧的接触压力（MainActor 转发，见 updateTouchMonitor）。
    func calibrationDidReceiveTouchPressures(_ pressures: [Double]) {
        guard let session = activeCalibrationSession else { return }
        for pressure in pressures {
            session.recordContactPressure(pressure)
        }
    }

    /// 校准/开关变化后重建监听，让点击 override 携带最新阈值。
    private func rebuildMonitorIfRunning() {
        guard status == .running, monitor?.isRunning == true else { return }
        monitor?.stop()
        startMonitor()
    }

    // MARK: - 数据页自动刷新

    private var dataRefreshTimer: Timer?
    private var pageCancellable: AnyCancellable?

    /// 数据页（总览/键盘/触控板）3 秒自动刷新 + 切页立即刷新。
    /// refresh() 为毫秒级全量合并，常驻低频定时无感；
    /// 实时页/设置页不刷（避免无谓全树重算）。
    private func startDataRefreshTimer() {
        guard dataRefreshTimer == nil else { return }
        let timer = Timer(timeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshIfShowingDataPage() }
        }
        RunLoop.main.add(timer, forMode: .common)
        dataRefreshTimer = timer
        guard pageCancellable == nil else { return }
        pageCancellable = $page.dropFirst().sink { [weak self] page in
            guard let self, self.status == .running else { return }
            switch page {
            case .overview, .keyboard, .trackpad: self.refresh()
            default: break
            }
        }
    }

    private func refreshIfShowingDataPage() {
        guard status == .running else { return }
        switch page {
        case .overview, .keyboard, .trackpad: refresh()
        default: break
        }
    }
}
