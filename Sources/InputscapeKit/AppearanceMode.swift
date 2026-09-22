import Foundation

/// 显示模式（夜览）三档选项，与设置页分段控件一一对应：
/// - `.dark`   开启夜览（强制深色）
/// - `.light`  关闭夜览（强制浅色）
/// - `.system` 跟随系统（随 macOS 深色模式设置自动切换）
///
/// 放在 Kit 层：纯数据 + 持久化协议，可被 XCTest 直接覆盖；
/// 把选择应用到 `NSApp.appearance` 的逻辑在 App 层 AppearanceManager。
public enum AppearanceMode: String, CaseIterable, Sendable {
    case dark = "dark"
    case light = "light"
    case system = "system"

    /// 设置页控件文案（顺序即 allCases 顺序：开启夜览 / 关闭夜览 / 跟随系统）。
    public var label: String {
        switch self {
        case .dark: return "开启夜览"
        case .light: return "关闭夜览"
        case .system: return "跟随系统"
        }
    }

    /// 给定系统当前是否深色，解析出最终应使用深色的开关。
    /// 手动档忽略系统状态；跟随系统档透传系统状态。
    public func resolvesToDark(systemIsDark: Bool) -> Bool {
        switch self {
        case .dark: return true
        case .light: return false
        case .system: return systemIsDark
        }
    }
}

/// 显示模式持久化协议。测试可注入内存实现；
/// 生产实现在下方（UserDefaults，rawValue 字符串）。
public protocol AppearanceModeStore {
    func load() -> AppearanceMode?
    func save(_ mode: AppearanceMode)
}

/// UserDefaults 持久化：键 `Inputscape.AppearanceMode`，存枚举 rawValue。
/// 与 DeviceProfile / ReduceMotion 同一套 UserDefaults 约定；
/// 应用重启后由 AppearanceManager 在启动时读回，恢复上次所选模式。
public struct UserDefaultsAppearanceStore: AppearanceModeStore {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard,
                key: String = "Inputscape.AppearanceMode") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> AppearanceMode? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return AppearanceMode(rawValue: raw)
    }

    public func save(_ mode: AppearanceMode) {
        defaults.set(mode.rawValue, forKey: key)
    }
}
