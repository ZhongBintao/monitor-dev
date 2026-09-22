import XCTest
@testable import InputscapeKit

/// 键盘主图规范测试：78 键 US ANSI MacBook Pro 是所有键盘页面的唯一真值。
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

    /// 功能行：esc + F1–F12 + Touch ID；Touch ID 与 delete 右缘对齐。
    func testFunctionRow() {
        let esc = KeyboardLayoutSpec.key(withID: "Escape")
        XCTAssertEqual(esc?.x ?? -99, 0, accuracy: 0.001)
        XCTAssertEqual(esc?.width ?? -99, 1, accuracy: 0.001)
        for i in 1...12 {
            let f = KeyboardLayoutSpec.key(withID: "F\(i)")
            XCTAssertNotNil(f)
            XCTAssertNotNil(f?.icon, "F\(i) 缺少功能图标")
            XCTAssertEqual(f?.caption, "F\(i)")
        }
        let touch = KeyboardLayoutSpec.key(withID: "TouchID")
        XCTAssertNotNil(touch)
        XCTAssertEqual(touch?.x ?? -99, 13.5, accuracy: 0.001, "Touch ID 应与 delete 右缘对齐")
        XCTAssertEqual(touch?.isObservable, false, "Touch ID 不产生可观察事件")
        XCTAssertNil(KeyCodeMapper.keyID(for: 0x73), "Touch ID 不应映射任何键码")
    }

    /// 方向键：左右全高、上下半高堆叠。
    func testArrowKeyStructure() {
        let left = KeyboardLayoutSpec.key(withID: "ArrowLeft")
        let up = KeyboardLayoutSpec.key(withID: "ArrowUp")
        let down = KeyboardLayoutSpec.key(withID: "ArrowDown")
        let right = KeyboardLayoutSpec.key(withID: "ArrowRight")

        XCTAssertEqual(left?.height, 1.0)
        XCTAssertEqual(right?.height, 1.0)
        XCTAssertEqual(up?.height, 0.5)
        XCTAssertEqual(down?.height, 0.5)
        XCTAssertEqual(up?.yOffset, 0.0)
        XCTAssertEqual(down?.yOffset, 0.5, "下方向键应占据下半格")
        XCTAssertEqual(up?.x, down?.x, "上下方向键应水平对齐")
        XCTAssertEqual(up?.width, 1.0)
    }

    /// 设计文档验收：两颗 command 键与 X 键右对齐；字母默认居中。
    func testCmdAndXAnchors() {
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CommandLeft")?.anchor, .trailing)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "CommandRight")?.anchor, .trailing)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "X")?.anchor, .trailing)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "A")?.anchor, .center)
        XCTAssertEqual(KeyboardLayoutSpec.key(withID: "Q")?.anchor, .center)
    }

    /// 数字行与标点双层标注：上方符号、下方数字/字符（US ANSI 对应关系）。
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
            if entry.id == "Backtick" || entry.id.hasPrefix("Digit") {
                XCTAssertEqual(key?.anchor, .leading, "\(entry.id) 双层标注应左对齐")
            }
        }
    }

    /// F / J 定位凸点，且仅这两颗键有。
    func testHomeIndicatorsOnFAndJOnly() {
        let withBumps = KeyboardLayoutSpec.keys.filter { $0.homeIndicator }.map { $0.id }
        XCTAssertEqual(Set(withBumps), ["F", "J"])
    }

    /// 修饰键同时具备图标与文字。
    func testModifierIconsAndCaptions() {
        let modifiers: [(String, KeycapIcon, String)] = [
            ("Fn", .globe, "fn"),
            ("ControlLeft", .control, "control"),
            ("OptionLeft", .option, "option"),
            ("OptionRight", .option, "option"),
            ("CommandLeft", .command, "command"),
            ("CommandRight", .command, "command"),
            ("ShiftLeft", .shift, "shift"),
            ("ShiftRight", .shift, "shift"),
            ("CapsLock", .capsLock, "caps lock"),
            ("Delete", .deleteLeft, "delete"),
        ]
        for (id, icon, caption) in modifiers {
            let key = KeyboardLayoutSpec.key(withID: id)
            XCTAssertEqual(key?.icon, icon, "\(id) 图标不符")
            XCTAssertEqual(key?.caption, caption, "\(id) 文字不符")
        }
        // 空格键无任何标注。
        let space = KeyboardLayoutSpec.key(withID: "Space")
        XCTAssertNil(space?.caption)
        XCTAssertNil(space?.icon)
        XCTAssertNil(space?.baseLabel)
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
