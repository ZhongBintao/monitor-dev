import Foundation
import Carbon
import InputscapeCore

/// 读取当前输入源的元数据（ID、类型、语言）。不读取任何文字、组字串或候选词。
/// TIS API 非线程安全，必须在主线程调用。
public enum InputSourceReader {

    /// 系统输入源切换的分布式通知（DistributedNotificationCenter）。
    public static let changedNotification =
        Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)

    @MainActor
    public static func current() -> InputSourceInfo? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property(_ key: CFString) -> AnyObject? {
            guard let pointer = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
        }
        let id = property(kTISPropertyInputSourceID) as? String ?? ""
        let type = property(kTISPropertyInputSourceType) as? String ?? ""
        let languages = property(kTISPropertyInputSourceLanguages) as? [String] ?? []
        return InputSourceInfo(id: id,
                               isKeyboardLayout: type == (kTISTypeKeyboardLayout as String),
                               languages: languages)
    }
}
