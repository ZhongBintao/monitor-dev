import AppKit
import InputscapeKit

/// 夜览（显示模式）管理器：切换核心逻辑的唯一入口。
///
/// 职责：
/// 1. **持久化**：用户选择写入 UserDefaultsAppearanceStore（键
///    `Inputscape.AppearanceMode`），应用重启后在 init 里读回并应用——
///    上次所选模式跨启动保持。
/// 2. **应用**：三档映射到 AppKit 原生外观机制——
///    - 开启夜览 → `NSApp.appearance = darkAqua`
///    - 关闭夜览 → `NSApp.appearance = aqua`
///    - 跟随系统 → `NSApp.appearance = nil`（交还系统，随系统切换）
/// 3. **即时同步**：NSApp.appearance 变化会传播到所有窗口的
///    effectiveAppearance，Theme 的动态颜色随之重新求值——
///    全部页面（含侧栏、弹层、图表）即时重绘，无需重启。
///
/// systemIsDark 仅用于设置页提示文案（"当前系统为深色/浅色"），
/// 通过分布式通知 AppleInterfaceThemeChanged 跟踪系统档位。
@MainActor
final class AppearanceManager: ObservableObject {

    static let shared = AppearanceManager()

    /// 用户所选显示模式（持久化；未设置过默认跟随系统）。
    @Published private(set) var mode: AppearanceMode
    /// 系统当前是否处于深色模式（读系统偏好，不受本应用覆盖影响）。
    @Published private(set) var systemIsDark: Bool

    private let store: AppearanceModeStore
    private var themeObserver: NSObjectProtocol?

    init(store: AppearanceModeStore = UserDefaultsAppearanceStore()) {
        self.store = store
        self.mode = store.load() ?? .system
        self.systemIsDark = AppearanceManager.readSystemIsDark()
        apply(self.mode)
        observeSystemTheme()
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
    }

    /// 设置页入口：保存选择并立即应用。
    func setMode(_ newMode: AppearanceMode) {
        guard newMode != mode else { return }
        mode = newMode
        store.save(newMode)
        apply(newMode)
    }

    /// 把模式写到 NSApp.appearance；nil = 跟随系统。
    /// 在应用对象创建的最早期调用也安全（NSApplication.shared 会按需创建）。
    private func apply(_ mode: AppearanceMode) {
        NSApplication.shared.appearance = switch mode {
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        case .system: nil
        }
    }

    /// 跟踪系统深浅色：跟随系统档下系统切换时，窗口外观由系统直接传播，
    /// 动态颜色自行重解析；这里只需刷新设置页的提示文案。
    private func observeSystemTheme() {
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("AppleInterfaceThemeChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.systemIsDark = AppearanceManager.readSystemIsDark()
            }
        }
    }

    /// 读系统级深色设置（键 AppleInterfaceStyle：深色时为 "Dark"，
    /// 浅色时键不存在；读的是系统偏好，不受 NSApp.appearance 覆盖影响）。
    private static func readSystemIsDark() -> Bool {
        UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }
}
