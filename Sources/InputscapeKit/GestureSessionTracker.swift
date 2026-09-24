import Foundation

/// 单次手势会话的方向判定（纯逻辑，无系统依赖，可单测）。
///
/// 一次 beginGesture → endGesture 之间收集 magnify / rotate 事件，
/// 会话结束时按净变化决定方向——每次手势只计 1 次（提案口径）。
/// 一个会话可同时产出缩放与旋转两类（如捏合并带旋转）。
///
/// 数据口径（依据本机 SDK 头文件 AppKit/NSEvent.h）：
/// - `magnification` 为**逐事件增量**（"change in magnification"），
///   直接累加即为手势净缩放变化；
/// - `rotation` 为自手势开始以来的**累计角度**，相邻帧差分累加得净变化；
///   符号按「正值 = 逆时针」处理，待真机标定校正（见 PROGRESS.md 标定清单）。
public struct GestureSessionTracker: Sendable {

    /// 放大/缩小净变化阈值：|净缩放| 低于 1%（0.01）视为误触不计。
    public static let magnifyNetThreshold: Double = 0.01
    /// 旋转净角度阈值（度）：|净角度| 低于 2° 视为误触不计。
    public static let rotateNetThreshold: Double = 2.0

    private var magnifyNet: Double = 0
    private var hasMagnify = false
    private var lastRotation: Double?
    private var rotationNet: Double = 0
    private var hasRotate = false

    public init() {}

    /// 累加一次放大手势事件（NSEvent.magnification，逐事件增量）。
    public mutating func addMagnification(_ delta: Double) {
        magnifyNet += delta
        hasMagnify = true
    }

    /// 累加一次旋转手势事件（NSEvent.rotation，自手势开始的累计角度）。
    public mutating func addRotation(_ cumulativeDegrees: Double) {
        if let last = lastRotation {
            rotationNet += cumulativeDegrees - last
        } else {
            // 首帧：手势开始时角度为 0，累计值即当前净变化。
            rotationNet += cumulativeDegrees
        }
        lastRotation = cumulativeDegrees
        hasRotate = true
    }

    /// 当前净方向的放大/缩小判定（实时页「进行中」展示用；无样本时为 nil）。
    /// 返回 true = 放大中。净方向随事件即时翻转，展示稳定不抖动。
    public var magnifyDirectionSoFar: Bool? {
        guard hasMagnify else { return nil }
        return magnifyNet >= 0
    }

    /// 手势结束：结算方向类别（缩放/旋转各按净方向至多 1 次），并重置以复用。
    @discardableResult
    public mutating func finish() -> [TrackpadOperationKind] {
        var kinds: [TrackpadOperationKind] = []
        if hasMagnify {
            if magnifyNet > Self.magnifyNetThreshold {
                kinds.append(.zoomIn)
            } else if magnifyNet < -Self.magnifyNetThreshold {
                kinds.append(.zoomOut)
            }
        }
        if hasRotate {
            if rotationNet > Self.rotateNetThreshold {
                kinds.append(.rotateCCW)
            } else if rotationNet < -Self.rotateNetThreshold {
                kinds.append(.rotateCW)
            }
        }
        reset()
        return kinds
    }

    public mutating func reset() {
        magnifyNet = 0
        hasMagnify = false
        lastRotation = nil
        rotationNet = 0
        hasRotate = false
    }
}
