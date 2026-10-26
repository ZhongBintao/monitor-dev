import Foundation

/// 一帧内的一个触点（坐标已归一化：x 左→右，y 上→下）。
public struct TouchPoint: Sendable, Equatable {
    public let id: Int32
    public let x: Double
    public let y: Double
    /// MTTouch offset 52 的按压力度（Phase 0 验证：静置 ~7，轻点 36–64，物理点击 173–255，重按 ~450）
    public let pressure: Double
    public let majorAxis: Double
    public let minorAxis: Double
    public let angle: Double

    public init(id: Int32, x: Double, y: Double, pressure: Double = 0,
                majorAxis: Double = 10, minorAxis: Double = 9, angle: Double = 0) {
        self.id = id
        self.x = x
        self.y = y
        self.pressure = pressure
        self.majorAxis = majorAxis
        self.minorAxis = minorAxis
        self.angle = angle
    }
}

/// 把 MultitouchSupport 的原始帧流变成统计贡献：接触时长、移动时长、落点、
/// 各网格接触时长，以及一次「触控会话」（首指落下 → 全部抬起）结束时的类型。
/// 只在 MT 回调线程上使用（非线程安全）。
public final class TouchTracker {

    /// 帧间隔上限：防止丢帧或休眠后的大间隔被算成接触时长。
    public static let maxFrameInterval: Double = 0.05
    /// 全部手指抬起后的宽限期：期间重新落下仍算同一会话。
    public static let sessionGrace: Double = 0.08
    /// 移动判定速度（归一化宽度 / 秒，平滑后）。约 8 mm/s，待 Phase 0 · P4 校准。
    public static let moveSpeedThreshold: Double = 0.05

    private struct Finger {
        var x: Double
        var y: Double
    }

    private var fingers: [Int32: Finger] = [:]
    private var lastFrameTime: Double?
    private var smoothedSpeed = 0.0

    // 会话特征
    private var session: SessionFeatures?
    private var emptySince: Double?

    public init() {}

    public struct Output: Equatable {
        public var contribution = TouchContribution()
        public var endedSession: TouchSessionKind?
        public var maxPressure = 0.0
        public var fingerCount = 0
    }

    public func ingest(time t: Double, touches: [TouchPoint]) -> Output {
        var out = Output()
        out.fingerCount = touches.count
        out.maxPressure = touches.map(\.pressure).max() ?? 0

        let dt: Double = {
            guard let last = lastFrameTime, !fingers.isEmpty else { return 0 }
            return min(max(0, t - last), Self.maxFrameInterval)
        }()
        lastFrameTime = t

        // 会话：空帧开始宽限；宽限过后再来手指 = 新会话
        if touches.isEmpty {
            if session != nil, emptySince == nil { emptySince = t }
        } else {
            if let since = emptySince, t - since > Self.sessionGrace, let s = session {
                out.endedSession = TouchSessionClassifier.classify(s)
                session = nil
            }
            emptySince = nil
            if session == nil { session = SessionFeatures(start: t) }
        }

        // 接触时长与各网格接触
        if !touches.isEmpty && dt > 0 {
            out.contribution.contactSeconds = dt
            for p in touches {
                out.contribution.contactMs[TouchGrid.cell(x: p.x, y: p.y), default: 0] += dt * 1000
            }
        }

        // 落点 + 移动
        let previousIDs = Set(fingers.keys)
        let currentIDs = Set(touches.map(\.id))
        for p in touches where !previousIDs.contains(p.id) {
            out.contribution.landings.append(TouchGrid.cell(x: p.x, y: p.y))
        }
        if dt > 0, !touches.isEmpty {
            var maxDisplacement = 0.0
            for p in touches {
                guard let f = fingers[p.id] else { continue }
                maxDisplacement = max(maxDisplacement, hypot(p.x - f.x, p.y - f.y))
            }
            let speed = maxDisplacement / dt
            smoothedSpeed = smoothedSpeed * 0.7 + speed * 0.3
            if smoothedSpeed > Self.moveSpeedThreshold {
                out.contribution.moveSeconds = dt
                out.contribution.moving = true
            }
        } else if touches.isEmpty {
            smoothedSpeed = 0
        }

        if var s = session, !touches.isEmpty {
            s.update(t: t, touches: touches, sameFingers: currentIDs == previousIDs)
            session = s
        }

        fingers = Dictionary(uniqueKeysWithValues: touches.map { ($0.id, Finger(x: $0.x, y: $0.y)) })
        return out
    }

    /// 定时调用：全部手指已抬起且宽限期已过的会话在此结束（MT 无触点时不再发帧）。
    public func flush(now t: Double) -> TouchSessionKind? {
        guard let s = session, fingers.isEmpty else { return nil }
        if let since = emptySince, t - since <= Self.sessionGrace { return nil }
        session = nil
        emptySince = nil
        return TouchSessionClassifier.classify(s)
    }

    /// 点击时会话内出现过点击（用于区分「按住拖动」与普通移动）。
    public func noteClick() {
        session?.hadClick = true
    }
}

// MARK: - 会话特征与分类

public struct SessionFeatures: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var maxFingers = 0
    /// 质心路径长度（归一化宽度），手指数变化的帧不计
    public var travel = 0.0
    /// 多指张开程度的最大变化（捏合 / 张开）
    public var spreadChange = 0.0
    public var hadClick = false

    private var lastCentroid: (x: Double, y: Double)?
    private var initialSpread: Double?

    public init(start: Double) {
        self.start = start
        self.end = start
    }

    public init(duration: Double, maxFingers: Int, travel: Double, spreadChange: Double = 0, hadClick: Bool = false) {
        self.start = 0
        self.end = duration
        self.maxFingers = maxFingers
        self.travel = travel
        self.spreadChange = spreadChange
        self.hadClick = hadClick
    }

    public var duration: Double { end - start }

    mutating func update(t: Double, touches: [TouchPoint], sameFingers: Bool) {
        end = t
        maxFingers = max(maxFingers, touches.count)
        let cx = touches.map(\.x).reduce(0, +) / Double(touches.count)
        let cy = touches.map(\.y).reduce(0, +) / Double(touches.count)
        if sameFingers, let last = lastCentroid {
            travel += hypot(cx - last.x, cy - last.y)
        }
        lastCentroid = (cx, cy)
        if touches.count >= 2 {
            let spread = touches.map { hypot($0.x - cx, $0.y - cy) }.reduce(0, +) / Double(touches.count)
            if let initial = initialSpread, sameFingers {
                spreadChange = max(spreadChange, abs(spread - initial))
            } else if !sameFingers || initialSpread == nil {
                initialSpread = spread
            }
        }
    }

    public static func == (lhs: SessionFeatures, rhs: SessionFeatures) -> Bool {
        lhs.start == rhs.start && lhs.end == rhs.end && lhs.maxFingers == rhs.maxFingers
            && lhs.travel == rhs.travel && lhs.spreadChange == rhs.spreadChange && lhs.hadClick == rhs.hadClick
    }
}

/// 会话分类（阈值为初值，待 Phase 0 夹具校准）。
public enum TouchSessionClassifier {
    public static let swipeTravel = 0.08
    public static let scrollTravel = 0.02
    public static let pointTravel = 0.015
    public static let pinchSpread = 0.04
    public static let tapDuration = 0.3

    public static func classify(_ s: SessionFeatures) -> TouchSessionKind {
        switch s.maxFingers {
        case 4...:
            return s.travel >= swipeTravel ? .swipe4 : .rest
        case 3:
            return s.travel >= swipeTravel ? .swipe3 : .rest
        case 2:
            if s.spreadChange >= pinchSpread && s.spreadChange >= s.travel * 0.5 { return .pinch }
            return s.travel >= scrollTravel ? .scroll : .rest
        default:
            if s.travel >= pointTravel { return .point }
            return s.duration <= tapDuration ? .tap : .rest
        }
    }
}

// MARK: - 点击分类

/// 点击类型：按点击前后时间窗内的触控板压力峰值判定（Phase 0 实测）。
public enum ClickClassifier {
    /// 轻点峰值 36–64、物理点击 173–255：阈值 110（已验证）。
    public static let tapPressureCeiling = 110.0
    /// 重按约 300 起（仅 1 个样本，待 P5 复测）。
    public static let heavyPressureFloor = 300.0
    /// 点击前后查找压力峰值的时间窗。
    public static let lookBehind = 0.06
    public static let lookAhead = 0.3

    public static func classify(isRightButton: Bool, peakPressure: Double?) -> ClickKind {
        guard let peak = peakPressure else { return .other }
        if isRightButton { return .right }
        if peak < tapPressureCeiling { return .tap }
        if peak >= heavyPressureFloor { return .heavy }
        return .press
    }
}

/// MT 线程写入、主线程读取的最近压力环（点击分类用）。只在内存，约 1 秒。
public final class PressureRing: @unchecked Sendable {
    private struct Sample { let t: Double; let pressure: Double; let fingers: Int }
    private let lock = NSLock()
    private var samples: [Sample] = []

    public init() {}

    public func record(t: Double, maxPressure: Double, fingers: Int) {
        lock.lock(); defer { lock.unlock() }
        samples.append(Sample(t: t, pressure: maxPressure, fingers: fingers))
        if let first = samples.first, t - first.t > 1.5 {
            samples.removeAll { t - $0.t > 1.0 }
        }
    }

    /// 时间窗内有接触时返回压力峰值；无接触返回 nil。
    public func peak(from start: Double, to end: Double) -> Double? {
        lock.lock(); defer { lock.unlock() }
        let window = samples.filter { $0.t >= start && $0.t <= end && $0.fingers > 0 }
        guard !window.isEmpty else { return nil }
        return window.map(\.pressure).max()
    }

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        samples.removeAll()
    }
}
