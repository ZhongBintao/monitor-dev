import Foundation
import CoreGraphics
import ApplicationServices

public struct PermissionStatus: Sendable, Equatable {
    /// 输入监控（CGEventTap 监听键盘所必需）
    public var inputMonitoring: Bool
    /// 辅助功能（全局鼠标事件所需）
    public var accessibility: Bool

    public var granted: Bool { inputMonitoring && accessibility }
}

public enum Permissions {

    public static func current() -> PermissionStatus {
        PermissionStatus(inputMonitoring: CGPreflightListenEventAccess(),
                         accessibility: AXIsProcessTrusted())
    }

    /// 触发系统授权弹窗（已授权时无副作用）。
    @discardableResult
    public static func request() -> PermissionStatus {
        _ = CGRequestListenEventAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return current()
    }
}
