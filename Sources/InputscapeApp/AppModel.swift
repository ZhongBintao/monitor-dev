import Foundation
import AppKit
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
    }

    private func startMonitor() {
        let engine = self.engine
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
                let kind: TrackpadOperationKind = deltaY > 0 ? .scrollUp : .scrollDown
                engine.ingestTrackpad(kind)
                Task { @MainActor in
                    LiveModel.shared.noteTrackpad(kind, inProgress: false)
                    AppModel.shared.scheduleSave()
                }
            },
            onClick: {
                engine.ingestTrackpad(.click)
                Task { @MainActor in
                    LiveModel.shared.noteTrackpad(.click, inProgress: false)
                    AppModel.shared.scheduleSave()
                }
            },
            onForceTouch: {
                engine.ingestTrackpad(.forceTouch)
                Task { @MainActor in
                    LiveModel.shared.noteTrackpad(.forceTouch, inProgress: false)
                    AppModel.shared.scheduleSave()
                }
            },
            onZoom: {
                engine.ingestTrackpad(.zoom)
                Task { @MainActor in
                    LiveModel.shared.noteTrackpad(.zoom, inProgress: false)
                    AppModel.shared.scheduleSave()
                }
            },
            onSwipe: {
                engine.ingestTrackpad(.swipe)
                Task { @MainActor in
                    LiveModel.shared.noteTrackpad(.swipe, inProgress: false)
                    AppModel.shared.scheduleSave()
                }
            },
            onGestureStart: {
                Task { @MainActor in LiveModel.shared.noteGestureStart() }
            },
            onMagnifyActive: {
                Task { @MainActor in LiveModel.shared.noteZoomInProgress() }
            },
            onGestureEnd: {
                Task { @MainActor in LiveModel.shared.noteGestureEnd() }
            }
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

    /// 顶栏 / 标题用的时段描述。
    public var rangeLabel: String {
        if let c = customRange {
            return c.start == c.end
                ? Self.shortDay(c.start)
                : "\(Self.shortDay(c.start)) ~ \(Self.shortDay(c.end))"
        }
        return scope.label
    }

    public static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return parts.suffix(2).joined(separator: "-")
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

    // MARK: - 减少动效

    public func setReduceMotion(_ value: Bool) {
        reduceMotion = value
        UserDefaults.standard.set(value, forKey: "Inputscape.ReduceMotion")
    }
}
