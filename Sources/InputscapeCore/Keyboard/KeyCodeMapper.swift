import Foundation

/// Apple ANSI 物理键码（kVK_*，公开常量）→ 本项目物理键位 ID。
/// 监听层只允许输出这里的键位 ID，不得读取或记录字符内容。
public enum KeyCodeMapper {

    /// kVK_ANSI_* / kVK_* 公开键码表（US ANSI 内置键盘）。
    public static let map: [UInt64: String] = [
        // 字母
        0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G",
        0x06: "Z", 0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q",
        0x0D: "W", 0x0E: "E", 0x0F: "R", 0x10: "Y", 0x11: "T",
        0x1F: "O", 0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L",
        0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
        // 数字行
        0x12: "Digit1", 0x13: "Digit2", 0x14: "Digit3", 0x15: "Digit4",
        0x17: "Digit5", 0x16: "Digit6", 0x1A: "Digit7", 0x1C: "Digit8",
        0x19: "Digit9", 0x1D: "Digit0", 0x18: "Equal", 0x1B: "Minus",
        0x32: "Backtick", 0x33: "Delete",
        // Tab 行
        0x30: "Tab", 0x21: "BracketLeft", 0x1E: "BracketRight", 0x2A: "Backslash",
        // Caps 行
        0x39: "CapsLock", 0x27: "Quote", 0x29: "Semicolon", 0x24: "Return",
        // Shift 行
        0x2B: "Comma", 0x2F: "Period", 0x2C: "Slash",
        // 修饰键
        0x38: "ShiftLeft", 0x3C: "ShiftRight",
        0x3B: "ControlLeft",
        0x3A: "OptionLeft", 0x3D: "OptionRight",
        0x37: "CommandLeft", 0x36: "CommandRight",
        0x31: "Space", 0x3F: "Fn",
        // 功能行
        0x35: "Escape",
        0x7A: "F1", 0x78: "F2", 0x63: "F3", 0x76: "F4",
        0x60: "F5", 0x61: "F6", 0x62: "F7", 0x64: "F8",
        0x65: "F9", 0x6D: "F10", 0x67: "F11", 0x6F: "F12",
        // 方向键
        0x7B: "ArrowLeft", 0x7C: "ArrowRight", 0x7D: "ArrowDown", 0x7E: "ArrowUp",
    ]

    /// 物理键码 → 键位 ID；未收录的键码（第三方键盘、小键盘等）一律丢弃。
    public static func keyID(for keyCode: UInt64) -> String? {
        map[keyCode]
    }

    /// 反查：键位 ID → 键码（测试与视图高亮用）。
    public static func keyCode(for keyID: String) -> UInt64? {
        map.first(where: { $0.value == keyID })?.key
    }

    // MARK: - 系统媒体键（F 行默认行为）

    /// 默认设置下，物理 F1/F2/F7–F12 不产生标准 keyDown，而是
    /// systemDefined（type 14, subtype 8）媒体事件。此表把
    /// NX_KEYTYPE（IOKit ev_keymap.h 公开常量）映射回物理键位 ID：
    /// 无论系统如何派发，统计始终绑定物理键位。
    /// 注意 F5（听写）/F6（勿扰）没有公开可观察事件，属已知边界。
    public static let mediaKeyMap: [Int: String] = [
        3: "F1",   // NX_KEYTYPE_BRIGHTNESS_DOWN
        2: "F2",   // NX_KEYTYPE_BRIGHTNESS_UP
        20: "F7",  // NX_KEYTYPE_REWIND
        16: "F8",  // NX_KEYTYPE_PLAY
        19: "F9",  // NX_KEYTYPE_FAST
        7: "F10",  // NX_KEYTYPE_MUTE
        1: "F11",  // NX_KEYTYPE_SOUND_DOWN
        0: "F12",  // NX_KEYTYPE_SOUND_UP
    ]

    /// Apple Silicon 上 F3（调度中心）/ F4（启动台或聚焦）以特殊键码
    /// 走标准 keyDown（Karabiner 生态的 apple_vendor_top_case 键码）。
    /// 另一组：fn 按住时系统会改写键码——fn+←/→/↑/↓ 实际发送
    /// Home(115)/End(119)/PageUp(116)/PageDown(121)，fn+delete 发送
    /// ForwardDelete(117)（kVK_* 公开常量，Carbon Events.h）。
    /// 统计绑定物理键位，因此把这些键码映射回方向键与 Delete；
    /// 否则 fn+⌃/⌘+方向键这类组合会因键码不在表里而整体丢失。
    public static let specialKeyMap: [UInt64: String] = [
        130: "F3",         // Mission Control
        131: "F4",         // Launchpad / Spotlight（随系统版本，物理键位同为 F4）
        115: "ArrowLeft",  // fn+← → Home
        119: "ArrowRight", // fn+→ → End
        116: "ArrowUp",    // fn+↑ → Page Up
        121: "ArrowDown",  // fn+↓ → Page Down
        117: "Delete",     // fn+delete → Forward Delete
    ]

    /// 媒体键解析：data1 高 16 位为 NX_KEYTYPE。
    public static func keyID(forMediaData1 data1: Int64) -> String? {
        let keyType = Int((data1 & 0xFFFF0000) >> 16)
        return mediaKeyMap[keyType]
    }

    /// 媒体键 data1 低 16 位：bits 8-15 == 0xA 表示按下（0xB 释放），bit 0 为重复。
    public static func isMediaKeyDown(_ data1: Int64) -> Bool {
        let keyFlags = data1 & 0x0000FFFF
        return ((keyFlags & 0xFF00) >> 8) == 0xA
    }

    public static func isMediaKeyRepeat(_ data1: Int64) -> Bool {
        (data1 & 0x1) != 0
    }
}

// MARK: - 组合键（和弦）

/// 修饰键集合，ID 构造按 macOS 菜单显示顺序 ⌃⌥⇧⌘。
public enum ComboModifier: String, Codable, Sendable, CaseIterable, Comparable {
    case control, option, shift, command

    public var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
        }
    }

    /// 菜单显示顺序：⌃ < ⌥ < ⇧ < ⌘。
    private var order: Int {
        switch self {
        case .control: return 0
        case .option: return 1
        case .shift: return 2
        case .command: return 3
        }
    }

    public static func < (lhs: ComboModifier, rhs: ComboModifier) -> Bool {
        lhs.order < rhs.order
    }
}

public enum ComboKeyBuilder {

    /// 组合键 ID：修饰键按菜单顺序拼接 + 主键键帽文字（如 "⌘C"、"⇧⌘3"）。
    /// 只描述「按住修饰键时按下了哪个物理键」的和弦，不含时间信息。
    public static func comboID(modifiers: [ComboModifier], keyID: String) -> String {
        let sorted = modifiers.sorted()
        let prefix = sorted.map { $0.symbol }.joined()
        return prefix + keyLabel(for: keyID)
    }

    /// 主键显示文字：优先键帽下层字符 / 功能文字（与主键盘图一致）；
    /// 功能文字按 macOS 快捷键习惯首字母大写（键帽 "delete" → "Delete"）。
    public static func keyLabel(for keyID: String) -> String {
        guard let key = KeyboardLayoutSpec.key(withID: keyID) else { return keyID }
        if let base = key.baseLabel { return base }
        if let word = key.word { return word.localizedCapitalized }
        return keyID
    }
}
