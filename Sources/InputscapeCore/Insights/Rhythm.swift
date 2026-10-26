import Foundation

/// 节奏与疲劳指标（REFACTOR_PLAN.md §6）：全部从每分钟数据纯函数推导，口径改了可重算。
public enum Rhythm {

    /// 一分钟 active_s ≥ 10 秒才算活跃分钟。
    public static let activeMinuteSeconds = 10.0
    /// 连续 ≥ 5 分钟无输入 = 休息。
    public static let breakMinutes = 5
    /// 超过 60 分钟的连续段 = 长时间未休息。
    public static let longStretchMinutes = 60
    /// 专注段：≥ 25 分钟且活跃分钟占比 ≥ 60 %。
    public static let focusMinutes = 25
    public static let focusDensity = 0.6
    /// 深夜：逻辑日起点（04:00）后 19 小时 = 23:00 起。
    public static let lateNightOffsetMinutes = 19 * 60

    public enum MinuteState: Equatable, Sendable {
        case active, idle, offline, unknown
    }

    public struct Stretch: Equatable, Sendable {
        /// 首个活跃分钟
        public let start: Int
        /// 末个活跃分钟 + 1（开区间）
        public let end: Int
        public let activeMinutes: Int
        /// 边界挨着「未知」时段（暂停 / 未运行），实际可能更长
        public let incomplete: Bool

        public var length: Int { end - start }
        public var density: Double { length > 0 ? Double(activeMinutes) / Double(length) : 0 }
    }

    public struct Span: Equatable, Sendable {
        public let start: Int
        public let end: Int
        public var length: Int { end - start }
    }

    public struct Summary: Equatable, Sendable {
        public var activeMinutes = 0
        public var activeSeconds = 0.0
        public var stretches: [Stretch] = []
        /// 段与段之间 ≥ 5 分钟的空档（时间轴灰带）
        public var breaks: [Span] = []
        /// 状态未知（暂停 / 应用未运行 / 无权限）
        public var unknown: [Span] = []
        public var lateNightMinutes = 0
        public var firstActiveMinute: Int?
        public var lastActiveMinute: Int?
        /// 仍在进行中的段（仅今天，最后活跃距现在 < 5 分钟）
        public var current: Stretch?

        public var longest: Stretch? { stretches.max { $0.length < $1.length } }
        public var longStretches: [Stretch] { stretches.filter { $0.length > Rhythm.longStretchMinutes } }
        public var focusBlocks: [Stretch] {
            stretches.filter { $0.length >= Rhythm.focusMinutes && $0.density >= Rhythm.focusDensity }
        }
    }

    /// - Parameters:
    ///   - range: 逻辑日的分钟区间
    ///   - activeSeconds: 分钟 → active_s（各输入源已求和）
    ///   - coverage: 分钟 → 采集状态；缺失 = 应用未运行
    ///   - now: 当前分钟（今天时截断到现在，之后的分钟不算未知）
    public static func summarize(range: Range<Int>,
                                 activeSeconds: [Int: Double],
                                 coverage: [Int: CoverageState],
                                 now: Int? = nil) -> Summary {
        var summary = Summary()
        let upper = min(range.upperBound, (now ?? Int.max - 1) + 1)
        guard upper > range.lowerBound else { return summary }

        func state(_ m: Int) -> MinuteState {
            let seconds = activeSeconds[m] ?? 0
            if seconds >= activeMinuteSeconds { return .active }
            switch coverage[m] {
            case .recording?, .mtUnavailable?: return .idle
            case .asleep?, .locked?: return .offline
            case .paused?, .noPermission?, .lab?, nil:
                // 有少量活动但未达阈值、又没有覆盖记录（旧版本 / 时钟边界）时按空闲处理
                return seconds > 0 ? .idle : .unknown
            }
        }

        var openStart: Int?
        var openIncomplete = false
        var lastActive: Int?
        var openActiveCount = 0
        var unknownStart: Int?

        func close(incompleteEnd: Bool) {
            guard let s = openStart, let last = lastActive else { return }
            summary.stretches.append(Stretch(start: s, end: last + 1, activeMinutes: openActiveCount,
                                             incomplete: openIncomplete || incompleteEnd))
            openStart = nil
            openIncomplete = false
            openActiveCount = 0
        }

        var previousState: MinuteState?
        for m in range.lowerBound..<upper {
            let st = state(m)
            if st == .unknown {
                if unknownStart == nil { unknownStart = m }
            } else if let u = unknownStart {
                summary.unknown.append(Span(start: u, end: m))
                unknownStart = nil
            }

            switch st {
            case .active:
                summary.activeMinutes += 1
                if m - range.lowerBound >= lateNightOffsetMinutes { summary.lateNightMinutes += 1 }
                if summary.firstActiveMinute == nil { summary.firstActiveMinute = m }
                if let last = lastActive, openStart != nil, m - last - 1 >= breakMinutes {
                    close(incompleteEnd: false)
                }
                if openStart == nil {
                    openStart = m
                    openIncomplete = previousState == .unknown
                }
                openActiveCount += 1
                lastActive = m
            case .idle:
                break
            case .offline:
                close(incompleteEnd: false)
            case .unknown:
                // 未知紧接在段之后：段可能还在继续，标记不完整
                if openStart != nil, let last = lastActive, m - last - 1 < breakMinutes {
                    close(incompleteEnd: true)
                } else {
                    close(incompleteEnd: false)
                }
            }
            previousState = st
        }
        if let u = unknownStart { summary.unknown.append(Span(start: u, end: upper)) }

        let stillOpen = openStart != nil
        let openSnapshot: Stretch? = {
            guard let s = openStart, let last = lastActive else { return nil }
            return Stretch(start: s, end: last + 1, activeMinutes: openActiveCount, incomplete: openIncomplete)
        }()
        close(incompleteEnd: false)

        if let n = now, stillOpen, let open = openSnapshot, n - (open.end - 1) < breakMinutes {
            summary.current = open
        }

        summary.lastActiveMinute = lastActive
        summary.activeSeconds = activeSeconds.filter { range.contains($0.key) }.values.reduce(0, +)

        // 段之间的休息（时间轴灰带）
        for (a, b) in zip(summary.stretches, summary.stretches.dropFirst()) where b.start - a.end >= breakMinutes {
            summary.breaks.append(Span(start: a.end, end: b.start))
        }
        return summary
    }
}
