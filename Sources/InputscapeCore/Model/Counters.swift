import Foundation

// MARK: - 每分钟计数列（与 minute_activity 表一一对应）

/// minute_activity 的全部计数列。rawValue 即 SQLite 列名。
/// 单位各不相同（次 / 秒 / 像素），展示时从不跨单位相加。
public enum Counter: String, CaseIterable, Codable, Sendable {
    case activeSeconds = "active_s"

    case keyLetter = "key_letter"
    case keySpace = "key_space"
    case keyDelete = "key_delete"
    case keyReturn = "key_return"
    case keyNav = "key_nav"
    case keyDigitPunct = "key_digit_punct"
    case keyModifier = "key_modifier"
    case keyFunction = "key_function"
    /// 按住产生的自动重复：单独记录，不算按键。
    case keyRepeat = "key_repeat"
    case shortcuts

    case clickPress = "click_press"
    case clickTap = "click_tap"
    case clickHeavy = "click_heavy"
    case clickRight = "click_right"
    /// 内置触控板无接触时的点击（外接鼠标等），不展示。
    case clickOther = "click_other"

    case scrollVerticalPx = "scroll_v_px"
    case scrollHorizontalPx = "scroll_h_px"
    case scrollMomentumPx = "scroll_momentum_px"

    /// 至少一根手指接触的挂钟秒数（多指重叠只算一次）。
    case touchSeconds = "touch_s"
    /// 有手指在移动的秒数（静置不算）。
    case touchMoveSeconds = "touch_move_s"
    /// 指针移动秒数：仅在触控板不可用时作为活动的兜底来源。
    case pointerSeconds = "pointer_s"

    case sessionTap = "sess_tap"
    case sessionPoint = "sess_point"
    case sessionScroll = "sess_scroll"
    case sessionPinch = "sess_pinch"
    case sessionSwipe3 = "sess_swipe3"
    case sessionSwipe4 = "sess_swipe4"
    case sessionRest = "sess_rest"

    /// 计入「按键数」的列（不含自动重复）。
    public static let keyPresses: [Counter] = [
        .keyLetter, .keySpace, .keyDelete, .keyReturn,
        .keyNav, .keyDigitPunct, .keyModifier, .keyFunction
    ]

    /// 计入「点击数」的列（内置触控板）。
    public static let trackpadClicks: [Counter] = [.clickPress, .clickTap, .clickHeavy, .clickRight]

    public static let sessions: [Counter] = [
        .sessionTap, .sessionPoint, .sessionScroll, .sessionPinch,
        .sessionSwipe3, .sessionSwipe4, .sessionRest
    ]
}

/// 一组计数（稀疏字典，缺省为 0）。
public struct Counters: Equatable, Sendable, Codable {
    public private(set) var values: [Counter: Double] = [:]

    public init(_ values: [Counter: Double] = [:]) {
        self.values = values.filter { $0.value != 0 }
    }

    public subscript(_ counter: Counter) -> Double {
        get { values[counter] ?? 0 }
        set { values[counter] = newValue == 0 ? nil : newValue }
    }

    public mutating func add(_ counter: Counter, _ amount: Double = 1) {
        guard amount != 0 else { return }
        self[counter] += amount
    }

    public mutating func merge(_ other: Counters) {
        for (counter, value) in other.values { add(counter, value) }
    }

    public var isEmpty: Bool { values.isEmpty }

    public func sum(_ counters: [Counter]) -> Double {
        counters.reduce(0) { $0 + self[$1] }
    }

    public var keyPresses: Int { Int(sum(Counter.keyPresses)) }
    public var clicks: Int { Int(sum(Counter.trackpadClicks)) }
    public var scrollPixels: Double { self[.scrollVerticalPx] + self[.scrollHorizontalPx] }
}

// MARK: - 枚举

public enum ClickKind: String, Codable, Sendable, CaseIterable {
    /// 物理按下（咔哒）
    case press
    /// 轻点（tap-to-click）
    case tap
    /// 重按（第二档）
    case heavy
    /// 右键 / 辅助点按
    case right
    /// 内置触控板无接触（外接鼠标等）
    case other

    public var counter: Counter {
        switch self {
        case .press: return .clickPress
        case .tap: return .clickTap
        case .heavy: return .clickHeavy
        case .right: return .clickRight
        case .other: return .clickOther
        }
    }
}

public enum TouchSessionKind: String, Codable, Sendable, CaseIterable {
    case tap, point, scroll, pinch, swipe3, swipe4, rest

    public var counter: Counter {
        switch self {
        case .tap: return .sessionTap
        case .point: return .sessionPoint
        case .scroll: return .sessionScroll
        case .pinch: return .sessionPinch
        case .swipe3: return .sessionSwipe3
        case .swipe4: return .sessionSwipe4
        case .rest: return .sessionRest
        }
    }
}

/// 每分钟的采集状态（coverage 表）。没有记录的分钟 = 应用没在运行。
public enum CoverageState: String, Codable, Sendable, CaseIterable {
    case recording
    case paused
    case asleep
    case locked
    case noPermission = "no_permission"
    /// 键盘照常记录，但触控板（MultitouchSupport）不可用
    case mtUnavailable = "mt_unavailable"
    /// Lab 协议录制中：事件不进统计
    case lab
}

// MARK: - 触控板网格

public enum TouchGrid {
    public static let columns = 24
    public static let rows = 16
    public static let cellCount = columns * rows

    /// 归一化坐标（x 左→右，y 上→下）→ 网格索引。
    public static func cell(x: Double, y: Double) -> Int {
        let col = min(columns - 1, max(0, Int(x * Double(columns))))
        let row = min(rows - 1, max(0, Int(y * Double(rows))))
        return row * columns + col
    }
}
