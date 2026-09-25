import Foundation

// MARK: - 滚动会话化（去抖核心）

/// 把 macOS 连续投递的 scrollWheel 事件流聚合为「一次滚动动作」。
///
/// 根因：触控板一次双指滑动会以 60–125Hz 连续投递 scrollWheel 事件
/// （手指移动阶段 + 手指离开后的惯性 momentum 阶段），逐事件计数会把
/// 单次滑动拆成几十次。成熟做法（pilotmoon/ScrollReverser 的相位+时间窗、
/// noah-nuebling/mac-mouse-fix 的 ScrollAnalyzer tick 间隔分析）共同模式：
/// 会话化——时间间隔小于阈值的连续事件并入同一会话，按会话计 1 次。
///
/// 方向语义：delta 沿用系统口径（>0 = 内容下移）。正负各自累计 |delta|，
/// 会话结束取主导方向；总位移低于噪声门限的微动会话（轻触微动产生的
/// 事件串）直接丢弃，不计数。
/// 纯逻辑、无系统依赖，供 EventMonitor 驱动并可单测。
public struct ScrollSessionAccumulator: Sendable {

    /// 会话静默间隔（秒）：与上一滚动事件间隔超过该值即视为新会话。
    /// 惯性 momentum 事件间隔通常 < 16ms，自然并入会话尾。
    public var gap: TimeInterval
    /// 会话最小位移（|delta| 累计，行单位）：低于该值的会话视为微动噪声。
    public var minimumDisplacement: Double

    public private(set) var positiveSum: Double = 0
    public private(set) var negativeSum: Double = 0
    private var lastEventAt: TimeInterval?

    /// 是否有未结算的会话。
    public var hasActiveSession: Bool { lastEventAt != nil }

    public init(gap: TimeInterval = 0.25, minimumDisplacement: Double = 3.0) {
        self.gap = gap
        self.minimumDisplacement = minimumDisplacement
    }

    /// 新滚动事件并入会话；若与上一事件间隔超 gap，先结算上一会话。
    /// 返回被结算会话的主导方向（+1 = 内容下移 / -1 = 内容上移），无则 nil。
    public mutating func accept(delta: Double, at t: TimeInterval) -> Double? {
        var emitted: Double?
        if let last = lastEventAt, t - last > gap {
            emitted = flush()
        }
        if delta > 0 { positiveSum += delta } else { negativeSum += -delta }
        lastEventAt = t
        return emitted
    }

    /// 结束当前会话（无会话返回 nil）。主导方向：正负累计相等取上移侧
    /// （滚动中途反向时，末段意图通常更接近用户最终动作的对立面——
    /// 取等号走 -1 只是边界约定，实际位移相等几乎不出现）。
    @discardableResult
    public mutating func flush() -> Double? {
        defer {
            positiveSum = 0
            negativeSum = 0
            lastEventAt = nil
        }
        guard lastEventAt != nil else { return nil }
        let displacement = positiveSum + negativeSum
        guard displacement >= minimumDisplacement else { return nil }
        return positiveSum >= negativeSum ? 1 : -1
    }
}

// MARK: - 官方手势事件不应期（防重复投递）

/// 同类手势事件在不应期窗口内只接受第一次（吸收系统对单次手势的
/// 疑似重复投递，如 smartMagnify/swipe 连发）。
public struct GestureRefractoryGate: Sendable {

    /// 不应期（秒），真机探针标定后调整。
    public var interval: TimeInterval
    private var lastAcceptedAt: TimeInterval?

    public init(interval: TimeInterval = 0.3) {
        self.interval = interval
    }

    /// 返回是否接受该事件（接受即刷新时间戳）。
    public mutating func shouldAccept(at t: TimeInterval) -> Bool {
        if let last = lastAcceptedAt, t - last < interval { return false }
        lastAcceptedAt = t
        return true
    }

    public mutating func reset() {
        lastAcceptedAt = nil
    }
}
