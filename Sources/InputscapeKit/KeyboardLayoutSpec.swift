import Foundation

// MARK: - 键帽图标

/// 键帽上使用的图标（渲染层映射到 SF Symbols / 自绘形状）。
public enum KeycapIcon: String, Codable, Sendable, CaseIterable {
    case sunLow          // F1 亮度降低
    case sunMax          // F2 亮度提高
    case missionControl  // F3 调度中心
    case spotlight       // F4 聚焦搜索
    case dictation       // F5 听写
    case doNotDisturb    // F6 勿扰
    case rewind          // F7
    case playPause       // F8
    case fastForward     // F9
    case mute            // F10
    case volumeDown      // F11
    case volumeUp        // F12
    case touchID         // Touch ID 指纹环
    case globe           // fn / 地球键
    case control         // ⌃
    case option          // ⌥
    case command         // ⌘
    case shift           // ⇧
    case capsLock        // ⇪
    case deleteLeft      // ⌫
    case arrowUp
    case arrowDown
    case arrowLeft
    case arrowRight
}

// MARK: - 文字锚点

/// 键帽文字锚点：按主键盘图逐键定义，不采用统一居中规则。
public enum KeycapAnchor: String, Codable, Sendable {
    case leading   // 左对齐（数字/双层符号、tab、caps、fn/control/option、shift）
    case center    // 居中（字母、方向键图标、F 行图标与编号）
    case trailing  // 右对齐（两颗 command、X、delete、return）
}

// MARK: - 键位定义

/// 一个物理键位的完整定义。所有含键盘的页面从本结构渲染。
public struct KeyDefinition: Identifiable, Sendable, Equatable {
    /// 稳定物理键位 ID（统计绑定的就是它，不是字符）。
    public let id: String
    /// 行号 0..5。
    public let row: Int
    /// 行内 x 起点（单位 u，1u = 标准键距）。
    public let x: Double
    /// 宽度（u）。
    public let width: Double
    /// 高度（u，方向键上下键为 0.5，其余为 1）。
    public let height: Double
    /// 行内 y 偏移（u）：半高键在行内的垂直位置。
    public let yOffset: Double
    /// 双层标注：上方符号（Shift 后字符）。
    public let topSymbol: String?
    /// 双层标注：下方字符 / 字母。
    public let baseLabel: String?
    /// 修饰键 / 功能文字（如 "command"、"F1"）。
    public let caption: String?
    public let icon: KeycapIcon?
    public let anchor: KeycapAnchor
    /// 定位凸点（F / J）。
    public let homeIndicator: Bool
    /// 是否可被观察（Touch ID 不产生可观察事件）。
    public let isObservable: Bool

    public init(id: String, row: Int, x: Double, width: Double, height: Double = 1.0,
                yOffset: Double = 0.0,
                topSymbol: String? = nil, baseLabel: String? = nil, caption: String? = nil,
                icon: KeycapIcon? = nil, anchor: KeycapAnchor, homeIndicator: Bool = false,
                isObservable: Bool = true) {
        self.id = id
        self.row = row
        self.x = x
        self.width = width
        self.height = height
        self.yOffset = yOffset
        self.topSymbol = topSymbol
        self.baseLabel = baseLabel
        self.caption = caption
        self.icon = icon
        self.anchor = anchor
        self.homeIndicator = homeIndicator
        self.isObservable = isObservable
    }
}

// MARK: - 主键盘图规范

/// 78 键 US ANSI MacBook Pro（14/16 英寸，带 Touch ID、全高功能行）
/// 唯一键盘源。任何含键盘的页面（键盘分布 / 总览缩略 / 实时观察）
/// 都必须从本结构派生，禁止各自硬编码键位数组。
public enum KeyboardLayoutSpec {

    /// 单排总宽（u）：数字行 1+10+1+1+1.5 = 14.5。
    public static let rowUnits: Double = 14.5

    public static let rowCount = 6
    /// 每行键数：功能行 14、数字行 14、Tab 行 14、Caps 行 13、Shift 行 12、底行 11。
    public static let keysPerRow = [14, 14, 14, 13, 12, 11]
    public static let totalKeyCount = 78

    public static let keys: [KeyDefinition] = buildKeys()

    public static func key(withID id: String) -> KeyDefinition? {
        keyIndex[id]
    }

    private static let keyIndex: [String: KeyDefinition] = {
        Dictionary(uniqueKeysWithValues: keys.map { ($0.id, $0) })
    }()

    /// 所有可观察的物理键位（Touch ID 除外）。
    public static var observableKeys: [KeyDefinition] {
        keys.filter { $0.isObservable }
    }

    // MARK: - 构建

    private static func buildKeys() -> [KeyDefinition] {
        var out: [KeyDefinition] = []

        // ---- 第 0 行：功能行（esc、F1–F12、Touch ID）----
        out.append(KeyDefinition(id: "Escape", row: 0, x: 0, width: 1,
                                 caption: "esc", icon: nil, anchor: .leading))
        let functionIcons: [(KeycapIcon, String)] = [
            (.sunLow, "F1"), (.sunMax, "F2"), (.missionControl, "F3"), (.spotlight, "F4"),
            (.dictation, "F5"), (.doNotDisturb, "F6"), (.rewind, "F7"), (.playPause, "F8"),
            (.fastForward, "F9"), (.mute, "F10"), (.volumeDown, "F11"), (.volumeUp, "F12")
        ]
        for (i, pair) in functionIcons.enumerated() {
            out.append(KeyDefinition(id: "F\(i + 1)", row: 0, x: Double(i + 1), width: 1,
                                     caption: pair.1, icon: pair.0, anchor: .center))
        }
        // Touch ID 与 delete 右缘对齐（x = 13.5，右侧不留空隙）。
        out.append(KeyDefinition(id: "TouchID", row: 0, x: 13.5, width: 1,
                                 icon: .touchID, anchor: .center, isObservable: false))

        // ---- 第 1 行：数字行（上方符号 / 下方数字，左对齐双层标注）----
        let digitRow: [(String, String, String)] = [
            ("~", "`", "Backtick"), ("!", "1", "Digit1"), ("@", "2", "Digit2"),
            ("#", "3", "Digit3"), ("$", "4", "Digit4"), ("%", "5", "Digit5"),
            ("^", "6", "Digit6"), ("&", "7", "Digit7"), ("*", "8", "Digit8"),
            ("(", "9", "Digit9"), (")", "0", "Digit0"), ("_", "-", "Minus"),
            ("+", "=", "Equal")
        ]
        var x: Double = 0
        for (top, base, id) in digitRow {
            out.append(KeyDefinition(id: id, row: 1, x: x, width: 1,
                                     topSymbol: top, baseLabel: base, anchor: .leading))
            x += 1
        }
        out.append(KeyDefinition(id: "Delete", row: 1, x: 13, width: 1.5,
                                 caption: "delete", icon: .deleteLeft, anchor: .trailing))

        // ---- 第 2 行：Tab 行 ----
        out.append(KeyDefinition(id: "Tab", row: 2, x: 0, width: 1.5,
                                 caption: "tab", anchor: .leading))
        let topRowLetters = ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
        for (i, letter) in topRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 2, x: 1.5 + Double(i), width: 1,
                                     baseLabel: letter, anchor: .center))
        }
        out.append(KeyDefinition(id: "BracketLeft", row: 2, x: 11.5, width: 1,
                                 topSymbol: "{", baseLabel: "[", anchor: .leading))
        out.append(KeyDefinition(id: "BracketRight", row: 2, x: 12.5, width: 1,
                                 topSymbol: "}", baseLabel: "]", anchor: .leading))
        out.append(KeyDefinition(id: "Backslash", row: 2, x: 13.5, width: 1,
                                 topSymbol: "|", baseLabel: "\\", anchor: .leading))

        // ---- 第 3 行：Caps 行 ----
        out.append(KeyDefinition(id: "CapsLock", row: 3, x: 0, width: 1.75,
                                 caption: "caps lock", icon: .capsLock, anchor: .leading))
        let homeRowLetters = ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
        for (i, letter) in homeRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 3, x: 1.75 + Double(i), width: 1,
                                     baseLabel: letter, anchor: .center,
                                     homeIndicator: letter == "F" || letter == "J"))
        }
        out.append(KeyDefinition(id: "Semicolon", row: 3, x: 10.75, width: 1,
                                 topSymbol: ":", baseLabel: ";", anchor: .leading))
        out.append(KeyDefinition(id: "Quote", row: 3, x: 11.75, width: 1,
                                 topSymbol: "\"", baseLabel: "'", anchor: .leading))
        out.append(KeyDefinition(id: "Return", row: 3, x: 12.75, width: 1.75,
                                 caption: "return", anchor: .trailing))

        // ---- 第 4 行：Shift 行 ----
        out.append(KeyDefinition(id: "ShiftLeft", row: 4, x: 0, width: 2.25,
                                 caption: "shift", icon: .shift, anchor: .leading))
        let bottomRowLetters = ["Z", "X", "C", "V", "B", "N", "M"]
        for (i, letter) in bottomRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 4, x: 2.25 + Double(i), width: 1,
                                     baseLabel: letter, anchor: letter == "X" ? .trailing : .center))
        }
        out.append(KeyDefinition(id: "Comma", row: 4, x: 9.25, width: 1,
                                 topSymbol: "<", baseLabel: ",", anchor: .leading))
        out.append(KeyDefinition(id: "Period", row: 4, x: 10.25, width: 1,
                                 topSymbol: ">", baseLabel: ".", anchor: .leading))
        out.append(KeyDefinition(id: "Slash", row: 4, x: 11.25, width: 1,
                                 topSymbol: "?", baseLabel: "/", anchor: .leading))
        out.append(KeyDefinition(id: "ShiftRight", row: 4, x: 12.25, width: 2.25,
                                 caption: "shift", icon: .shift, anchor: .leading))

        // ---- 第 5 行：修饰键行 + 方向键组 ----
        out.append(KeyDefinition(id: "Fn", row: 5, x: 0, width: 1,
                                 caption: "fn", icon: .globe, anchor: .leading))
        out.append(KeyDefinition(id: "ControlLeft", row: 5, x: 1, width: 1,
                                 caption: "control", icon: .control, anchor: .leading))
        out.append(KeyDefinition(id: "OptionLeft", row: 5, x: 2, width: 1,
                                 caption: "option", icon: .option, anchor: .leading))
        out.append(KeyDefinition(id: "CommandLeft", row: 5, x: 3, width: 1,
                                 caption: "command", icon: .command, anchor: .trailing))
        out.append(KeyDefinition(id: "Space", row: 5, x: 4, width: 5.5,
                                 anchor: .center))
        out.append(KeyDefinition(id: "CommandRight", row: 5, x: 9.5, width: 1,
                                 caption: "command", icon: .command, anchor: .trailing))
        out.append(KeyDefinition(id: "OptionRight", row: 5, x: 10.5, width: 1,
                                 caption: "option", icon: .option, anchor: .leading))
        // 方向键组：左右全高、上下半高堆叠。
        out.append(KeyDefinition(id: "ArrowLeft", row: 5, x: 11.5, width: 1,
                                 icon: .arrowLeft, anchor: .center))
        out.append(KeyDefinition(id: "ArrowUp", row: 5, x: 12.5, width: 1, height: 0.5,
                                 yOffset: 0, icon: .arrowUp, anchor: .center))
        out.append(KeyDefinition(id: "ArrowDown", row: 5, x: 12.5, width: 1, height: 0.5,
                                 yOffset: 0.5, icon: .arrowDown, anchor: .center))
        out.append(KeyDefinition(id: "ArrowRight", row: 5, x: 13.5, width: 1,
                                 icon: .arrowRight, anchor: .center))

        return out
    }
}
