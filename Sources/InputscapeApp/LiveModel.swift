import Foundation
import InputscapeKit

/// 实时观察状态（仅内存）。独立于 AppModel：
/// 按键高频更新只失效订阅本模型的实时观察页，
/// 不再让整个视图树（侧栏 / 图表）跟着重算——这是此前
/// 「侧栏点击迟缓」的根因之一。
@MainActor
public final class LiveModel: ObservableObject {

    public static let shared = LiveModel()

    @Published public private(set) var state = LiveState()
    @Published public private(set) var lastIngestAt: Date?
    @Published public private(set) var lastComboID: String?
    /// 当前物理按住的键位（keyDown 点亮、keyUp 熄灭，实现跟手反馈）。
    @Published public private(set) var pressedKeys: Set<String> = []
    /// 每个按下键的时间戳，用于兜底清理丢失 keyUp 的残留。
    private var pressedAt: [String: Date] = [:]
    /// 实时触控板：当前接触中的手指（帧全量替换缓存，30Hz 合并发布）。
    private var liveTouchMap: [Int32: LiveState.TouchDot] = [:]
    private var lastTouchFrameAt: Date = .distantPast
    @Published public private(set) var touchDots: [LiveState.TouchDot] = []
    private var touchPulseTimer: Timer?
    /// 系统压力档（type 34 stage：1 轻按 / 2 重按）最近一次取值与时刻。
    /// 供按压测试与校准模块实时展示；仅内存。
    @Published public private(set) var pressureStage: Int = 0
    @Published public private(set) var pressureStageAt: Date?

    private init() {}

    // MARK: - 事件入口（由监听层经 AppModel 转发）

    public func noteKey(keyID: String) {
        state.lastKeyID = keyID
        state.lastKeyDownAt = Date()
        lastIngestAt = Date()
        pressedKeys.insert(keyID)
        pressedAt[keyID] = Date()
    }

    public func noteKeyUp(keyID: String) {
        pressedKeys.remove(keyID)
        pressedAt[keyID] = nil
    }

    /// 暂停 / 停止监听时清空"按下中"集合，防止 keyUp 丢失导致长亮。
    public func clearPressed() {
        pressedKeys.removeAll()
        pressedAt.removeAll()
        liveTouchMap.removeAll()
        touchDots = []
    }

    /// 兜底清理：单个键位按住超过 120 秒视为 keyUp 丢失（系统层偶发），
    /// 强制熄灭。正常长按（组合键按住思考）远低于该阈值。
    public func pruneStaleKeys(olderThan seconds: TimeInterval = 120) {
        let now = Date()
        for (keyID, at) in pressedAt where now.timeIntervalSince(at) > seconds {
            pressedKeys.remove(keyID)
            pressedAt[keyID] = nil
        }
    }

    public func noteCombo(_ comboID: String) {
        lastComboID = comboID
        lastIngestAt = Date()
    }

    public func noteTrackpad(_ kind: TrackpadOperationKind, inProgress: Bool) {
        state.recentTrackpad.insert(LiveState.TrackpadEvent(kind: kind, at: Date(), isInProgress: inProgress),
                                    at: 0)
        if state.recentTrackpad.count > LiveState.maxRecent {
            state.recentTrackpad.removeLast(state.recentTrackpad.count - LiveState.maxRecent)
        }
        lastIngestAt = Date()
    }

    // MARK: - 实时触控板（当前触点，仅内存）

    /// 触点帧接收（MT 回调线程 → MainActor 转发，~125Hz）。
    /// **帧全量替换**：以本帧触点集合覆盖缓存——本帧没有的手指即已离开，
    /// 触点数量与物理接触严格一致，手指离开立即消失（对齐 Kyome22 OMS
    /// Demo 的 touchDataStream 全量替换用法）。不直接触发发布——
    /// 发布由 30Hz 脉冲统一完成，避免实时页按回报率重绘。
    public func noteTouchFrame(_ frame: TouchFrame) {
        var newMap: [Int32: LiveState.TouchDot] = [:]
        for sample in frame.touches {
            newMap[sample.fingerID] = LiveState.TouchDot(
                fingerID: sample.fingerID,
                x: sample.x, y: sample.y, pressure: sample.pressure,
                majorAxis: sample.majorAxis, minorAxis: sample.minorAxis,
                angle: sample.angle)
        }
        liveTouchMap = newMap
        lastTouchFrameAt = Date()
        lastIngestAt = Date()
    }

    /// 启动 30Hz 发布脉冲（观察开始 / 触点监听运行时）。
    public func startTouchPulse() {
        guard touchPulseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.publishTouchDots() }
        }
        RunLoop.main.add(timer, forMode: .common)
        touchPulseTimer = timer
    }

    /// 停止脉冲并清空触点（暂停 / 权限撤销 / 退出观察）。
    public func stopTouchPulse() {
        touchPulseTimer?.invalidate()
        touchPulseTimer = nil
        liveTouchMap.removeAll()
        lastTouchFrameAt = .distantPast
        touchDots = []
    }

    private func publishTouchDots() {
        // 兜底：无接触时 MT 可能停止发帧（最后状态无空帧可清），
        // 超过 300ms 未收到新帧即视为全部离开，杜绝触点残留。
        if !liveTouchMap.isEmpty, Date().timeIntervalSince(lastTouchFrameAt) > 0.3 {
            liveTouchMap.removeAll()
        }
        touchDots = liveTouchMap.values.sorted { $0.fingerID < $1.fingerID }
    }

    // MARK: - 系统压力档（实时测试 / 校准展示）

    /// 压力档事件（EventMonitor 转发，主线程）。仅记录最近取值。
    public func notePressureStage(_ stage: Int, pressure: Double) {
        pressureStage = stage
        pressureStageAt = Date()
    }

    /// 当前有效压力档：超过 0.7 秒无新事件或 stage 为 0（悬停/离开）视为无接触。
    public func effectivePressureStage(now: Date = Date()) -> Int? {
        guard let at = pressureStageAt, now.timeIntervalSince(at) < 0.7 else { return nil }
        return pressureStage > 0 ? pressureStage : nil
    }

    // MARK: - 空闲

    public func markObservationStarted() {
        state.observationStartedAt = Date()
    }

    // MARK: - 当前按下的键（实时合并展示）

    /// 修饰类键位（CapsLock 按下也会点亮 ⇪ 徽章）。
    public static let modifierKeyIDs: Set<String> = [
        "CommandLeft", "CommandRight", "ControlLeft", "OptionLeft",
        "OptionRight", "ShiftLeft", "ShiftRight", "Fn", "CapsLock"
    ]

    private func modifierSymbol(_ id: String) -> String {
        switch id {
        case "CommandLeft", "CommandRight": return "⌘"
        case "ControlLeft": return "⌃"
        case "OptionLeft", "OptionRight": return "⌥"
        case "ShiftLeft", "ShiftRight": return "⇧"
        case "Fn": return "fn"
        case "CapsLock": return "⇪"
        default: return id
        }
    }

    /// 当前按住内容 → 展示徽章：
    /// - 只按住修饰键 → 各修饰键符号徽章；
    /// - 按住修饰键 + 普通键 → 每颗按住的普通键生成一条和弦徽章（⌘5 / ⇧⌘3）。
    public func heldChips() -> [String] {
        let held = pressedKeys
        guard !held.isEmpty else { return [] }
        let modifierHeld = held.intersection(Self.modifierKeyIDs)
        let comboMods: [ComboModifier] = modifierHeld.compactMap { id in
            switch id {
            case "CommandLeft", "CommandRight": return .command
            case "ControlLeft": return .control
            case "OptionLeft", "OptionRight": return .option
            case "ShiftLeft", "ShiftRight": return .shift
            default: return nil
            }
        }
        let mains = held.subtracting(Self.modifierKeyIDs)
        if mains.isEmpty {
            return modifierHeld.sorted().map { modifierSymbol($0) }
        }
        return mains.sorted().map { ComboKeyBuilder.comboID(modifiers: comboMods, keyID: $0) }
    }

    /// 距最近一次输入事件的秒数（实时页在 TimelineView 中每秒重取）。
    public func idleSeconds(now: Date = Date()) -> Int {
        guard let last = lastIngestAt else {
            if let started = state.observationStartedAt {
                return Int(now.timeIntervalSince(started))
            }
            return 0
        }
        return max(0, Int(now.timeIntervalSince(last)))
    }
}
