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

    public func noteGestureStart() {
        state.gestureInProgress = nil // 手势会话开始，方向待判别
    }

    /// 放大手势进行中（按净方向即时展示；计数在手势结束时结算）。
    public func noteZoomInProgress(zoomIn: Bool) {
        state.gestureInProgress = zoomIn ? .zoomIn : .zoomOut
    }

    public func noteGestureEnd() {
        state.gestureInProgress = nil
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
