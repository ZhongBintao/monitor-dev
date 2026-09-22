import Foundation

// MARK: - 键帽字形来源

/// 键帽图标来源：修饰键等使用标准 Unicode 字符（与 Apple 官方文档一致），
/// F1–F12 功能行使用 SF Symbols 官方矢量图标。
public enum KeyGlyph: Sendable, Equatable {
    /// Unicode 字符：⌘ U+2318、⌥ U+2325、⇧ U+21E7、⌃ U+2303、
    /// ⇪ U+21EA、⌫ U+232B、⏎ U+2324、⇥ U+21E5、▲▼◀▶ 方向三角
    case unicode(String)
    /// SF Symbols 官方矢量图标（功能行）
    case sfSymbol(String)
}

// MARK: - 键帽内容样式（逐键定义，与参考图一一对应）

public enum KeycapStyle: String, Sendable {
    case twin                 // 双层标注：上符号、下字符，水平居中（数字/标点行）
    case letter               // 字母，居中
    case fKey                 // 图标上、编号下，居中（F1–F12）
    case iconWordLeading      // 图标上、单词下，左对齐（左 fn 组/command/control）
    case iconWordTrailing     // 图标上、单词下，右对齐（右侧 command/option）
    case iconWordCorners      // 图标左下、单词右下，同排底对齐（fn）
    case iconCentered         // 图标居中（半高方向键）
    case iconLeadingMiddle    // 图标左、垂直居中（tab ⇥）
    case iconTrailingMiddle   // 图标右、垂直居中（delete ⌫ / return ⏎）
    case iconCornerLeading    // 图标左下（caps ⇪ / 左 shift ⇧）
    case iconCornerTrailing   // 图标右下（右 shift ⇧）
    case wordLeading          // 单词左下（esc）
    case touchID              // 触控 ID：裸圆环，无键帽边框
    case blank                // 空格：无任何标注
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
    /// 高度（u，半高键为 0.5，其余为 1）。
    public let height: Double
    /// 行内 y 偏移（u）：半高键在行内的垂直位置。
    public let yOffset: Double
    /// 双层标注：上方符号（Shift 后字符）。
    public let topSymbol: String?
    /// 双层标注：下方字符 / 字母。
    public let baseLabel: String?
    /// 单词标注（fn / control / option / command / F1…）。
    public let word: String?
    /// 图标字形（Unicode 或 SF Symbol）。
    public let glyph: KeyGlyph?
    public let style: KeycapStyle
    /// caps lock LED 指示点。
    public let ledIndicator: Bool
    /// 定位凸点（F / J）。
    public let homeIndicator: Bool
    /// 是否可被观察（Touch ID 不产生可观察事件）。
    public let isObservable: Bool

    public init(id: String, row: Int, x: Double, width: Double,
                height: Double = 1.0, yOffset: Double = 0.0,
                topSymbol: String? = nil, baseLabel: String? = nil,
                word: String? = nil, glyph: KeyGlyph? = nil,
                style: KeycapStyle, ledIndicator: Bool = false,
                homeIndicator: Bool = false, isObservable: Bool = true) {
        self.id = id
        self.row = row
        self.x = x
        self.width = width
        self.height = height
        self.yOffset = yOffset
        self.topSymbol = topSymbol
        self.baseLabel = baseLabel
        self.word = word
        self.glyph = glyph
        self.style = style
        self.ledIndicator = ledIndicator
        self.homeIndicator = homeIndicator
        self.isObservable = isObservable
    }
}

// MARK: - 主键盘图规范

/// 78 键唯一键盘源，物理布局采用 Apple 官方无线键盘实测数据
/// （`apple-wireless-keyboard.json`，KLE 格式，逐键 x/宽度已核对）：
/// - 功能行 14 键均为 1.0357u（14.5/14，JSON 实测值）；
/// - 底行 command 1.25u、space 5u（JSON 实测值）；
/// - 四个方向键均为半高（←/→ 底部对齐，↑ 顶部、↓ 底部）；
/// - 修饰键图标用标准 Unicode（⌘⌥⇧⌃⇪⌫⏎⇥），功能行用 SF Symbols。
/// 对 JSON 的两处修正（应用方约定）：
/// 1. 功能行高度 0.75 → 1.0，与字母键统一（底行 1.111 同理归一）；
/// 2. 忽略 JSON 的图标定义，键帽字形沿用本文件的 Unicode/SF 映射。
/// 任何含键盘的页面（键盘分布 / 总览缩略 / 实时观察）
/// 都必须从本结构派生，禁止各自硬编码键位数组。
/// 几何等价性由 KeyboardLayoutSpecTests 的 JSON 比对测试守护。
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
        // JSON 实测：14 键等宽 1.0357u（14.5/14），esc 与 F 键同宽、无空隙
        let fnKeyWidth = 14.5 / 14.0
        out.append(KeyDefinition(id: "Escape", row: 0, x: 0, width: fnKeyWidth,
                                 word: "esc", style: .wordLeading))
        let functionIcons: [(String, KeyGlyph)] = [
            ("F1", .sfSymbol("sun.min")), ("F2", .sfSymbol("sun.max")),
            ("F3", .sfSymbol("rectangle.split.2x2")), ("F4", .sfSymbol("magnifyingglass")),
            ("F5", .sfSymbol("mic")), ("F6", .sfSymbol("moon.fill")),
            ("F7", .sfSymbol("backward.fill")), ("F8", .sfSymbol("playpause.fill")),
            ("F9", .sfSymbol("forward.fill")), ("F10", .sfSymbol("speaker.slash.fill")),
            ("F11", .sfSymbol("speaker.wave.1.fill")), ("F12", .sfSymbol("speaker.wave.3.fill")),
        ]
        for (i, pair) in functionIcons.enumerated() {
            out.append(KeyDefinition(id: pair.0, row: 0, x: fnKeyWidth * Double(i + 1),
                                     width: fnKeyWidth, word: pair.0, glyph: pair.1,
                                     style: .fKey))
        }
        // 第 14 键：Touch ID（JSON 中该位为 A1314 的 eject 键，本应用映射为
        // Touch ID 圆环，键帽样式沿用现有 UI）；与 delete 右缘对齐。
        out.append(KeyDefinition(id: "TouchID", row: 0, x: fnKeyWidth * 13, width: fnKeyWidth,
                                 style: .touchID, isObservable: false))

        // ---- 第 1 行：数字行（上符号 / 下数字，居中双层标注）----
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
                                     topSymbol: top, baseLabel: base, style: .twin))
            x += 1
        }
        out.append(KeyDefinition(id: "Delete", row: 1, x: 13, width: 1.5,
                                 glyph: .unicode("⌫"), style: .iconTrailingMiddle))

        // ---- 第 2 行：Tab 行 ----
        out.append(KeyDefinition(id: "Tab", row: 2, x: 0, width: 1.5,
                                 glyph: .unicode("⇥"), style: .iconLeadingMiddle))
        let topRowLetters = ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"]
        for (i, letter) in topRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 2, x: 1.5 + Double(i), width: 1,
                                     baseLabel: letter, style: .letter))
        }
        out.append(KeyDefinition(id: "BracketLeft", row: 2, x: 11.5, width: 1,
                                 topSymbol: "{", baseLabel: "[", style: .twin))
        out.append(KeyDefinition(id: "BracketRight", row: 2, x: 12.5, width: 1,
                                 topSymbol: "}", baseLabel: "]", style: .twin))
        out.append(KeyDefinition(id: "Backslash", row: 2, x: 13.5, width: 1,
                                 topSymbol: "|", baseLabel: "\\", style: .twin))

        // ---- 第 3 行：Caps 行 ----
        out.append(KeyDefinition(id: "CapsLock", row: 3, x: 0, width: 1.75,
                                 glyph: .unicode("⇪"), style: .iconCornerLeading,
                                 ledIndicator: true))
        let homeRowLetters = ["A", "S", "D", "F", "G", "H", "J", "K", "L"]
        for (i, letter) in homeRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 3, x: 1.75 + Double(i), width: 1,
                                     baseLabel: letter, style: .letter,
                                     homeIndicator: letter == "F" || letter == "J"))
        }
        out.append(KeyDefinition(id: "Semicolon", row: 3, x: 10.75, width: 1,
                                 topSymbol: ":", baseLabel: ";", style: .twin))
        out.append(KeyDefinition(id: "Quote", row: 3, x: 11.75, width: 1,
                                 topSymbol: "\"", baseLabel: "'", style: .twin))
        out.append(KeyDefinition(id: "Return", row: 3, x: 12.75, width: 1.75,
                                 glyph: .unicode("⏎"), style: .iconTrailingMiddle))

        // ---- 第 4 行：Shift 行 ----
        out.append(KeyDefinition(id: "ShiftLeft", row: 4, x: 0, width: 2.25,
                                 glyph: .unicode("⇧"), style: .iconCornerLeading))
        let bottomRowLetters = ["Z", "X", "C", "V", "B", "N", "M"]
        for (i, letter) in bottomRowLetters.enumerated() {
            out.append(KeyDefinition(id: letter, row: 4, x: 2.25 + Double(i), width: 1,
                                     baseLabel: letter, style: .letter))
        }
        out.append(KeyDefinition(id: "Comma", row: 4, x: 9.25, width: 1,
                                 topSymbol: "<", baseLabel: ",", style: .twin))
        out.append(KeyDefinition(id: "Period", row: 4, x: 10.25, width: 1,
                                 topSymbol: ">", baseLabel: ".", style: .twin))
        out.append(KeyDefinition(id: "Slash", row: 4, x: 11.25, width: 1,
                                 topSymbol: "?", baseLabel: "/", style: .twin))
        out.append(KeyDefinition(id: "ShiftRight", row: 4, x: 12.25, width: 2.25,
                                 glyph: .unicode("⇧"), style: .iconCornerTrailing))

        // ---- 第 5 行：修饰键行 + 方向键组 ----
        // 参考图：fn/control/option/command 图标上、单词下，全部左对齐；
        // 四个方向键均为半高——←/→ 底部对齐，↑ 顶部、↓ 底部。
        // fn：地球左下、字母 fn 右下（与旁边 command 字母同一水平位置）
        out.append(KeyDefinition(id: "Fn", row: 5, x: 0, width: 1,
                                 word: "fn", glyph: .sfSymbol("globe"),
                                 style: .iconWordCorners))
        out.append(KeyDefinition(id: "ControlLeft", row: 5, x: 1, width: 1,
                                 word: "control", glyph: .unicode("⌃"),
                                 style: .iconWordLeading))
        out.append(KeyDefinition(id: "OptionLeft", row: 5, x: 2, width: 1,
                                 word: "option", glyph: .unicode("⌥"),
                                 style: .iconWordLeading))
        // JSON 实测：command 1.25u、space 5u（与现 MBP 布局的 1/5.5 不同）
        out.append(KeyDefinition(id: "CommandLeft", row: 5, x: 3, width: 1.25,
                                 word: "command", glyph: .unicode("⌘"),
                                 style: .iconWordLeading))
        out.append(KeyDefinition(id: "Space", row: 5, x: 4.25, width: 5, style: .blank))
        out.append(KeyDefinition(id: "CommandRight", row: 5, x: 9.25, width: 1.25,
                                 word: "command", glyph: .unicode("⌘"),
                                 style: .iconWordTrailing))
        out.append(KeyDefinition(id: "OptionRight", row: 5, x: 10.5, width: 1,
                                 word: "option", glyph: .unicode("⌥"),
                                 style: .iconWordTrailing))
        out.append(KeyDefinition(id: "ArrowLeft", row: 5, x: 11.5, width: 1, height: 0.5,
                                 yOffset: 0.5, glyph: .unicode("◀"), style: .iconCentered))
        out.append(KeyDefinition(id: "ArrowUp", row: 5, x: 12.5, width: 1, height: 0.5,
                                 yOffset: 0, glyph: .unicode("▲"), style: .iconCentered))
        out.append(KeyDefinition(id: "ArrowDown", row: 5, x: 12.5, width: 1, height: 0.5,
                                 yOffset: 0.5, glyph: .unicode("▼"), style: .iconCentered))
        out.append(KeyDefinition(id: "ArrowRight", row: 5, x: 13.5, width: 1, height: 0.5,
                                 yOffset: 0.5, glyph: .unicode("▶"), style: .iconCentered))

        return out
    }
}
