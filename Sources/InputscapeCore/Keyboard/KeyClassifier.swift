import Foundation

/// 物理键位 → 计数列。分类只看物理键位 ID，与输入法、大小写无关。
public enum KeyClassifier {

    private static let navKeys: Set<String> = [
        "ArrowLeft", "ArrowRight", "ArrowUp", "ArrowDown", "Tab", "Escape"
    ]

    private static let modifierKeys: Set<String> = [
        "ShiftLeft", "ShiftRight", "ControlLeft", "OptionLeft", "OptionRight",
        "CommandLeft", "CommandRight", "Fn", "CapsLock"
    ]

    public static func counter(for keyID: String) -> Counter {
        switch keyID {
        case "Space": return .keySpace
        case "Delete": return .keyDelete
        case "Return": return .keyReturn
        default: break
        }
        if navKeys.contains(keyID) { return .keyNav }
        if modifierKeys.contains(keyID) { return .keyModifier }
        if keyID.count == 1, let c = keyID.unicodeScalars.first, CharacterSet.uppercaseLetters.contains(c) {
            return .keyLetter
        }
        if keyID.hasPrefix("F"), Int(keyID.dropFirst()) != nil { return .keyFunction }
        return .keyDigitPunct
    }

    public static func isModifier(_ keyID: String) -> Bool { modifierKeys.contains(keyID) }

    /// 数字键 1–9（拼音输入时用于选候选词）。
    public static func isCandidateDigit(_ keyID: String) -> Bool {
        guard keyID.hasPrefix("Digit"), let n = Int(keyID.dropFirst(5)) else { return false }
        return (1...9).contains(n)
    }
}

/// 快捷键判定：只有 ⌘ 或 ⌃ 按住时才算（⌥ / ⇧ 单独按住产生的是字符，不是快捷键）。
public enum ShortcutRule {
    public static func comboID(modifiers: Set<ComboModifier>, keyID: String) -> String? {
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return nil }
        guard !KeyClassifier.isModifier(keyID) else { return nil }
        return ComboKeyBuilder.comboID(modifiers: Array(modifiers), keyID: keyID)
    }
}
