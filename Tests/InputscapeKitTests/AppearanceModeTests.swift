import XCTest
@testable import InputscapeKit

/// 夜览显示模式：枚举语义、解析规则与 UserDefaults 持久化回环。
final class AppearanceModeTests: XCTestCase {

    private static let suiteName = "InputscapeTests.AppearanceMode"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: Self.suiteName)
        defaults = UserDefaults(suiteName: Self.suiteName)
    }

    override func tearDown() {
        defaults?.removePersistentDomain(forName: Self.suiteName)
        super.tearDown()
    }

    // MARK: - 枚举语义

    func testThreeModesWithSpecifiedLabels() {
        XCTAssertEqual(AppearanceMode.allCases,
                       [.dark, .light, .system],
                       "分段控件顺序：开启夜览 / 关闭夜览 / 跟随系统")
        XCTAssertEqual(AppearanceMode.dark.label, "开启夜览")
        XCTAssertEqual(AppearanceMode.light.label, "关闭夜览")
        XCTAssertEqual(AppearanceMode.system.label, "跟随系统")
        XCTAssertEqual(AppearanceMode.dark.rawValue, "dark")
        XCTAssertEqual(AppearanceMode.light.rawValue, "light")
        XCTAssertEqual(AppearanceMode.system.rawValue, "system")
    }

    func testResolvesToDarkMatrix() {
        // 手动开启：无论系统状态都深色
        XCTAssertTrue(AppearanceMode.dark.resolvesToDark(systemIsDark: true))
        XCTAssertTrue(AppearanceMode.dark.resolvesToDark(systemIsDark: false))
        // 手动关闭：无论系统状态都浅色
        XCTAssertFalse(AppearanceMode.light.resolvesToDark(systemIsDark: true))
        XCTAssertFalse(AppearanceMode.light.resolvesToDark(systemIsDark: false))
        // 跟随系统：透传系统状态
        XCTAssertTrue(AppearanceMode.system.resolvesToDark(systemIsDark: true))
        XCTAssertFalse(AppearanceMode.system.resolvesToDark(systemIsDark: false))
    }

    // MARK: - 持久化

    func testUserDefaultsRoundTripAcrossInstances() {
        // 写入与读取用不同实例，模拟「本次选择 → 应用重启后读回」。
        let writer = UserDefaultsAppearanceStore(defaults: defaults)
        writer.save(.dark)
        let reader = UserDefaultsAppearanceStore(defaults: defaults)
        XCTAssertEqual(reader.load(), .dark)

        writer.save(.light)
        XCTAssertEqual(reader.load(), .light)

        writer.save(.system)
        XCTAssertEqual(reader.load(), .system)
    }

    func testUnsetKeyLoadsNil() {
        XCTAssertNil(UserDefaultsAppearanceStore(defaults: defaults).load(),
                     "未设置过时返回 nil，UI 层回退到默认档（跟随系统）")
    }

    func testCorruptStoredValueLoadsNil() {
        // 未来版本 / 手工改动导致未知 rawValue 时不得崩溃，按未设置处理。
        defaults.set("midnight", forKey: "Inputscape.AppearanceMode")
        XCTAssertNil(UserDefaultsAppearanceStore(defaults: defaults).load())
    }
}
