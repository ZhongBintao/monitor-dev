import Foundation

// MARK: - 输入源（只是元数据：ID、类型、语言；从不读取文字或候选词）

/// 输入源类别（存储用 rawValue）。
public enum InputSourceKind: String, Codable, Sendable, CaseIterable {
    case zhPinyin = "zh_pinyin"
    case zhOther = "zh_other"
    case ja, ko, latin, other

    public var isChinese: Bool { self == .zhPinyin || self == .zhOther }
}

/// 一个输入源的元数据快照。
public struct InputSourceInfo: Codable, Sendable, Equatable, Hashable {
    /// 如 `com.apple.keylayout.ABC`、`com.apple.inputmethod.SCIM.ITABC`
    public let id: String
    /// TIS 类型为键盘布局（而非输入法 / 输入模式）
    public let isKeyboardLayout: Bool
    /// kTISPropertyInputSourceLanguages，首项为主语言
    public let languages: [String]

    public init(id: String, isKeyboardLayout: Bool, languages: [String]) {
        self.id = id
        self.isKeyboardLayout = isKeyboardLayout
        self.languages = languages
    }

    public var kind: InputSourceKind { InputSourceClassifier.classify(self) }

    /// 读取失败时的占位。
    public static let unknown = InputSourceInfo(id: "", isKeyboardLayout: false, languages: [])
}

/// 纯函数分类：原始 ID 入库，规则变了可重新分类。
public enum InputSourceClassifier {

    /// 拼音类输入法 ID 片段（小写匹配）：系统拼音 / 双拼 / 微信输入法 / 搜狗。
    static let pinyinMarkers = ["pinyin", "itabc", "shuangpin", "wetype", "sogou"]

    public static func classify(_ source: InputSourceInfo) -> InputSourceKind {
        // 仅内置 US ANSI 键盘的个人工具：键盘布局一律视为英文输入。
        if source.isKeyboardLayout { return .latin }
        let id = source.id.lowercased()
        let language = source.languages.first?.lowercased() ?? ""
        if language.hasPrefix("zh") || id.contains(".scim.") || id.contains(".tcim.") {
            return pinyinMarkers.contains(where: id.contains) ? .zhPinyin : .zhOther
        }
        if language.hasPrefix("ja") { return .ja }
        if language.hasPrefix("ko") { return .ko }
        return .other
    }
}
