import XCTest
@testable import InputscapeKit

/// 键盘主图规范测试：78 键 US ANSI MacBook Pro 是所有键盘页面的唯一真值，
/// 布局与参考图逐键对齐（四方向键半高、右 Shift 图标右下、Unicode 修饰键字形）。
final class KeyboardLayoutSpecTests: XCTestCase {

    func testTotalKeyCountIs78WithUniqueIDs() {
        XCTAssertEqual(KeyboardLayoutSpec.keys.count, 78)
        XCTAssertEqual(KeyboardLayoutSpec.totalKeyCount, 78)
        let ids = KeyboardLayoutSpec.keys.map { $0.id }
        XCTAssertEqual(Set(ids).count, 78, "物理键位 ID 必须唯一")
    }

    func testKeysPerRow() {
        XCTAssertEqual(KeyboardLayoutSpec.keysPerRow, [14, 14, 14, 13, 12, 11])
        for row in 0..<6 {
            let count = KeyboardLayoutSpec.keys.filter { $0.row == row }.count
            XCTAssertEqual(count, KeyboardLayoutSpec.keysPerRow[row], "第 \(row) 行键数不符")
        }
    }

    /// 各行内容宽度必须一致（14.5u），保证物理比例对齐。
    func testAllRowsSpanTheSameWidth() {
        for row in 0..<KeyboardLayoutSpec.rowCount {
            let keys = KeyboardLayoutSpec.keys.filter { $0.row == row }
            let span = keys.map { $0.x + $0.width }.max() ?? 0
            XCTAssertEqual(span, KeyboardLayoutSpec.rowUnits, accuracy: 0.001, "第 \(row) 行右缘不符")
            let left = keys.map { $0.x }.min() ?? 0
            XCTAssertEqual(left, 0, accuracy: 0.001, "第 \(row) 行左缘不符")
        }
    }

    /// 宽度不同的特殊键：Tab/Delete 1.5、Caps/Return 1.75、Shift 2.25、Space 5.5。
    func testSpecialKeyWidths() {
        func width(_ id: String) -> Double {
            guard let key = KeyboardLayoutSpec.key(withID: id) else {
                XCTFail("缺少键位 \(id)")
                return 0
            }
            return key.width
        }
        XCTAssertEqual(width("Tab"), 1.5, accuracy: 0.001)
        XCTAssertEqual(width("Delete"), 1.5, accuracy: 0.001)
        XCTAssertEqual(width("CapsLock"), 1.75, accuracy: 0.001)
        XCTAssertEqual(width("Return"), 1.75, accuracy: 0.001)
        XCTAssertEqual(width("ShiftLeft"), 2.25, accuracy: 0.001)
        XCTAssertEqual(width("ShiftRight"), 2.25, accuracy: 0.001)
        XCTAssertEqual(width("Space"), 5.5, accuracy: 0.001)
        for letter in "QWERTYUIOPASDFGHJKLZXCVBNM" {
            XCTAssertEqual(width(String(letter)), 1.0, accuracy: 0.001)
        }
    }

    /// 功能行：esc + F1–F12（SF Symbols 官方图标）+ Touch ID（裸圆环）。
    func testFunctionRow() {
        let esc = KeyboardLayoutSpec.key(withID: "Escape")
        XCTAssertEqual(esc?.x ?? -99, 0, accuracy: 0.001)
        XCTAssertEqual(esc?.style, .wordLeading)
        XCTAssertEqual(esc?.word, "esc")

        for i in 1...12 {
            let f = KeyboardLayoutSpec.key(withID: "F\(i)")
            XCTAssertNotNil(f)
            guard case .sfSymbol(let name)? = f?.glyph else {
                XCTFail("F\(i) 应使用 SF Symbols 图标")
                return
            }
            XCTAssertFalse(name.isEmpty)
            XCTAssertEqual(f?.word, "F\(i)")
            XCTAssertEqual(f?.style, .fKey)
        }

        let touch = KeyboardLayoutSpec.key(withID: "TouchID")
        XCTAssertNotNil(touch)
        XCTAssertEqual(touch?.x ?? -99, 13.5, accuracy: 0.001, "Touch ID 应与 delete 右缘对齐")
        XCTAssertEqual(touch?.style, .touchID, "Touch ID 参考图为裸圆环样式")
        XCTAssertEqual(touch?.isObservable, false, "Touch ID 不产生可观察事件")
        XCTAssertNil(KeyCodeMapper.keyID(for: 0x73), "Touch ID 不应映射任何键码")
    }

    /// 方向键（参考图）：四个方向键全部为半高键——
    /// ↑ 顶部对齐，←/↓/→ 底部对齐；字形为 Unicode 方向三角。
    func testArrowKeysAllHalfHeight() {
        let expectations: [(String, Double, KeyGlyph, Double)] = [
            ("ArrowLeft", 0.5, .unicode("◀"), 0.5),
            ("ArrowUp", 0.5, .unicode("▲"), 0.0),
            ("ArrowDown", 0.5, .unicode("▼"), 0.5),
            ("ArrowRight", 0.5, .unicode("▶"), 0.5),
        ]
        for (id, height, glyph, yOffset) in expectations {
            let key = KeyboardLayoutSpec.key(withID: id)
            XCTAssertEqual(key?.height, height, "\(id) 应为半高键")
            XCTAssertEqual(key?.yOffset ?? -99, yOffset, accuracy: 0.001, "\(id) 垂直位置不符")
            XCTAssertEqual(key?.glyph, glyph, "\(id) 应使用 Unicode 方向三角")
            XCTAssertEqual(key?.width ?? -99, 1.0, accuracy: 0.001)
            XCTAssertEqual(key?.style, .iconCentered)
        }
        // ↑ 与 ↓ 水平对齐（同一列堆叠）
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "ArrowUp")?.x,
                       KeyboardLayoutSpec.key(withID: "ArrowDown")?.x)
        // ← → 底部对齐（同一垂直位置）
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "ArrowLeft")?.yOffset,
                       KeyboardLayoutSpec.key(withID: "ArrowRight")?.yOffset)
    }

    /// 双层标注：上方符号、下方字符（US ANSI 对应关系），居中。
    func testDoubleLayerLabels() {
        let cases: [(id: String, top: String, base: String)] = [
            ("Backtick", "~", "`"),
            ("Digit1", "!", "1"), ("Digit2", "@", "2"), ("Digit3", "#", "3"),
            ("Digit4", "$", "4"), ("Digit5", "%", "5"), ("Digit6", "^", "6"),
            ("Digit7", "&", "7"), ("Digit8", "*", "8"), ("Digit9", "(", "9"),
            ("Digit0", ")", "0"),
            ("Minus", "_", "-"), ("Equal", "+", "="),
            ("BracketLeft", "{", "["), ("BracketRight", "}", "]"),
            ("Backslash", "|", "\\"),
            ("Semicolon", ":", ";"), ("Quote", "\"", "'"),
            ("Comma", "<", ","), ("Period", ">", "."), ("Slash", "?", "/"),
        ]
        for entry in cases {
            let key = KeyboardLayoutSpec.key(withID: entry.id)
            XCTAssertEqual(key?.topSymbol, entry.top, "\(entry.id) 上层符号不符")
            XCTAssertEqual(key?.baseLabel, entry.base, "\(entry.id) 下层字符不符")
            XCTAssertEqual(key?.style, .twin, "\(entry.id) 应为居中双层标注")
        }
    }

    /// F / J 定位凸点，且仅这两颗键有。
    func testHomeIndicatorsOnFAndJOnly() {
        let withBumps = KeyboardLayoutSpec.keys.filter { $0.homeIndicator }.map { $0.id }
        XCTAssertEqual(Set(withBumps), ["F", "J"])
    }

    /// 修饰键字形：标准 Unicode 字符（与 Apple 官方文档一致）；
    /// fn 地球键用 SF Symbols（参考图为线框球形，Unicode 🌐 是彩色 emoji）。
    func testModifierGlyphsUseUnicode() {
        let unicodeCases: [(String, String, String?)] = [
            ("ControlLeft", "⌃", "control"),
            ("OptionLeft", "⌥", "option"),
            ("OptionRight", "⌥", "option"),
            ("CommandLeft", "⌘", "command"),
            ("CommandRight", "⌘", "command"),
            ("ShiftLeft", "⇧", nil),
            ("ShiftRight", "⇧", nil),
            ("CapsLock", "⇪", nil),
            ("Delete", "⌫", nil),
            ("Return", "⏎", nil),
            ("Tab", "⇥", nil),
        ]
        for (id, glyph, word) in unicodeCases {
            let key = KeyboardLayoutSpec.key(withID: id)
            XCTAssertEqual(key?.glyph, .unicode(glyph), "\(id) 应使用 Unicode 字形 \(glyph)")
            XCTAssertEqual(key?.word, word, "\(id) 单词标注不符")
        }
        // fn：SF Symbols 线框球形
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Fn")?.glyph, .sfSymbol("globe"))
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Fn")?.word, "fn")
        // CapsLock 带 LED 指示点
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CapsLock")?.ledIndicator, true)
    }

    /// 键帽内容位置（参考图逐键）：底行修饰键图标上/单词下左对齐；
    /// 左 shift 左下、右 shift 右下；delete/return 右侧垂直居中；tab 左侧垂直居中。
    func testKeycapContentStyles() {
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Fn")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "ControlLeft")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "OptionLeft")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CommandLeft")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CommandRight")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "OptionRight")?.style, .iconWordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "ShiftLeft")?.style, .iconCornerLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "ShiftRight")?.style, .iconCornerTrailing,
                       "右 Shift 的 ⇧ 图标应右下对齐")
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Delete")?.style, .iconTrailingMiddle)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Return")?.style, .iconTrailingMiddle)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Tab")?.style, .iconLeadingMiddle)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CapsLock")?.style, .iconCornerLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Escape")?.style, .wordLeading)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Space")?.style, .blank)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "A")?.style, .letter)
    }

    /// 同一行内键位几何不得重叠（允许共享边缘；同列上下堆叠的半高键除外）。
    func testNoGeometryOverlapWithinRows() {
        for row in 0..<KeyboardLayoutSpec.rowCount {
            let keys = KeyboardLayoutSpec.keys.filter { $0.row == row }
            for i in 0..<keys.count {
                for j in (i + 1)..<keys.count {
                    let a = keys[i], b = keys[j]
                    let xOverlap = min(a.x + a.width, b.x + b.width) - max(a.x, b.x) > 0.0001
                    let aTop = a.yOffset, aBottom = a.yOffset + a.height
                    let bTop = b.yOffset, bBottom = b.yOffset + b.height
                    let yOverlap = min(aBottom, bBottom) - max(aTop, bTop) > 0.0001
                    XCTAssertFalse(xOverlap && yOverlap,
                                   "\(row) 行内 \(a.id) 与 \(b.id) 几何重叠")
                }
            }
        }
    }

    /// 修饰键行：fn/control/option/command 左组 + 空格 + command/option 右组 + 方向键组。
    func testBottomRowOrder() {
        let bottom = KeyboardLayoutSpec.keys.filter { $0.row == 5 }.sorted { $0.x < $1.x }
        let ids = bottom.map { $0.id }
        XCTAssertEqual(ids, ["Fn", "ControlLeft", "OptionLeft", "CommandLeft", "Space",
                             "CommandRight", "OptionRight", "ArrowLeft", "ArrowUp", "ArrowDown", "ArrowRight"])
    }
}
