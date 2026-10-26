import SwiftUI
import AppKit
import InputscapeCore
import InputscapeStore
import InputscapeCapture

@main
struct InputscapeApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Inputscape", id: "main") {
            RootView()
                .environment(AppEnvironment.shared.state)
                .environment(AppEnvironment.shared.capture)
                .environment(\.database, AppEnvironment.shared.database)
        }
        .defaultSize(width: 1240, height: 880)
        .windowResizability(.contentMinSize)

        MenuBarExtra {
            MenuBarGlance()
                .environment(AppEnvironment.shared.state)
                .environment(AppEnvironment.shared.capture)
                .environment(\.database, AppEnvironment.shared.database)
        } label: {
            Image(systemName: "keyboard.badge.waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

/// 全局单例：数据库、采集主管、界面状态。
@MainActor
final class AppEnvironment {
    static let shared = AppEnvironment()

    let database: InputscapeDatabase
    let capture: CaptureSupervisor
    let state = AppState()

    private init() {
        do {
            database = try InputscapeDatabase.openDefault()
        } catch {
            // 打不开数据库时退回内存库：仍可运行，但不保存（设置页会提示）
            NSLog("Inputscape: database open failed: \(error)")
            database = try! InputscapeDatabase.inMemory()
            state.databaseError = error.localizedDescription
        }
        capture = CaptureSupervisor(database: database)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            let env = AppEnvironment.shared
            if let dir = SnapshotRenderer.requestedDirectory {
                SnapshotRenderer.run(into: dir, environment: env)
                exit(0)
            }
            env.capture.start()
            // 旧版 JSON 只读导入（幂等）
            let db = env.database
            Task.detached(priority: .utility) {
                if let dir = try? LegacyImporter.defaultDirectory() {
                    _ = try? LegacyImporter.importAll(from: dir, into: db)
                }
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NSApp.windows.first { $0.identifier?.rawValue == "main" }?.makeKeyAndOrderFront(nil) }
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard SnapshotRenderer.requestedDirectory == nil else { return }
        MainActor.assumeIsolated {
            AppEnvironment.shared.capture.shutdown()
        }
    }
}

// MARK: - 数据库注入

private struct DatabaseKey: EnvironmentKey {
    static let defaultValue: InputscapeDatabase? = nil
}

extension EnvironmentValues {
    var database: InputscapeDatabase? {
        get { self[DatabaseKey.self] }
        set { self[DatabaseKey.self] = newValue }
    }
}
