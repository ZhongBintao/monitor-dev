import Testing
import Foundation
@testable import InputscapeCore

/// 物理键码映射：监听层只输出键位 ID，不输出字符。
struct KeyCodeMapperTests {

    @Test func testKnownANSIKeycodes() {
        let cases: [(UInt64, String)] = [
            (0x00, "A"), (0x07, "X"), (0x03, "F"), (0x26, "J"),
            (0x12, "Digit1"), (0x1D, "Digit0"),
            (0x24, "Return"), (0x31, "Space"), (0x33, "Delete"),
            (0x30, "Tab"), (0x32, "Backtick"), (0x35, "Escape"), (0x39, "CapsLock"),
            (0x37, "CommandLeft"), (0x36, "CommandRight"),
            (0x38, "ShiftLeft"), (0x3C, "ShiftRight"),
            (122, "F1"), (120, "F2"), (99, "F3"), (111, "F12"),
            (123, "ArrowLeft"), (124, "ArrowRight"), (125, "ArrowDown"), (126, "ArrowUp"),
            (63, "Fn"),
        ]
        for (code, id) in cases {
            #expect(KeyCodeMapper.keyID(for: code) == id, "键码 \(code) 应映射为 \(id)")
            #expect(KeyCodeMapper.keyCode(for: id) == code, "\(id) 反查键码不符")
        }
    }

    @Test func testUnknownKeycodesAreDropped() {
        // 小键盘、F13+、ControlRight（内置 ANSI 无右 Control）等一律丢弃。
        #expect(KeyCodeMapper.keyID(for: 0x51) == nil) // keypad
        #expect(KeyCodeMapper.keyID(for: 0x69) == nil) // F13
        #expect(KeyCodeMapper.keyID(for: 0x3E) == nil) // ControlRight
        #expect(KeyCodeMapper.keyID(for: 9999) == nil)
    }

    /// 所有映射目标必须是主键盘图中的真实键位。
    @Test func testMappedIDsAllExistInSpec() {
        for (_, keyID) in KeyCodeMapper.map {
            #expect(KeyboardLayoutSpec.key(withID: keyID) != nil, "映射目标 \(keyID) 不在 78 键主键盘中")
        }
    }

    /// 主键盘中除 Touch ID 外的每个键位都应有键码映射（保证统计可覆盖）。
    /// 注：F5/F6 在默认系统设置下没有公开可观察事件，属已知边界，
    /// 故 mediaKeyMap/specialKeyMap 覆盖不到它们——排除后其余键位必须可达。
    @Test func testAllObservableKeysAreCoverable() {
        let mappedIDs = Set(KeyCodeMapper.map.values)
            .union(KeyCodeMapper.mediaKeyMap.values)
            .union(KeyCodeMapper.specialKeyMap.values)
        let knownUnobservable: Set<String> = ["F5", "F6"]
        for key in KeyboardLayoutSpec.observableKeys {
            if knownUnobservable.contains(key.id) { continue }
            #expect(mappedIDs.contains(key.id), "键位 \(key.id) 缺少键码映射")
        }
    }

    /// 系统媒体键（systemDefined data1）→ 物理 F 键：默认设置下按 F1
    /// 产生 BRIGHTNESS_DOWN(3)，必须计入物理键位 F1。
    @Test func testMediaKeyMapping() {
        let cases: [(Int64, String)] = [
            (mediaData1(3), "F1"),   // 亮度降低 → F1
            (mediaData1(2), "F2"),   // 亮度提高 → F2
            (mediaData1(20), "F7"),  // 上一曲 → F7
            (mediaData1(16), "F8"),  // 播放/暂停 → F8
            (mediaData1(19), "F9"),  // 下一曲 → F9
            (mediaData1(7), "F10"),  // 静音 → F10
            (mediaData1(1), "F11"),  // 音量减 → F11
            (mediaData1(0), "F12"),  // 音量加 → F12
        ]
        for (data1, id) in cases {
            #expect(KeyCodeMapper.keyID(forMediaData1: data1) == id)
            #expect(KeyCodeMapper.isMediaKeyDown(data1))
            #expect(!(KeyCodeMapper.isMediaKeyRepeat(data1)))
        }
        // 释放状态与重复不计数。
        #expect(!(KeyCodeMapper.isMediaKeyDown(mediaData1(3, keyState: 0xB))))
        #expect(KeyCodeMapper.isMediaKeyRepeat(mediaData1(3, keyState: 0xA, repeatBit: true)))
        // 未收录类型（如 POWER=6）不映射。
        #expect(KeyCodeMapper.keyID(forMediaData1: mediaData1(6)) == nil)
    }

    private func mediaData1(_ keyType: Int, keyState: Int = 0xA, repeatBit: Bool = false) -> Int64 {
        var data1: Int64 = Int64(keyType) << 16
        data1 |= Int64(keyState) << 8
        if repeatBit { data1 |= 1 }
        return data1
    }

    /// Apple Silicon 特殊键码：F3 调度中心 / F4 启动台（聚焦）。
    @Test func testSpecialKeycodes() {
        #expect(KeyCodeMapper.specialKeyMap[130] == "F3")
        #expect(KeyCodeMapper.specialKeyMap[131] == "F4")
    }

    /// fn 按住时系统改写键码：fn+方向键发送 Home/End/PageUp/PageDown，
    /// fn+delete 发送 ForwardDelete（kVK_* 公开常量）。
    /// 组合统计绑定物理键位，必须映射回方向键与 Delete，
    /// 否则 fn+⌃/⌘+方向键（如 fn+⌃+↑）整个组合会丢失。
    @Test func testFnRemappedKeycodes() {
        #expect(KeyCodeMapper.specialKeyMap[115] == "ArrowLeft")  // fn+← → Home
        #expect(KeyCodeMapper.specialKeyMap[119] == "ArrowRight") // fn+→ → End
        #expect(KeyCodeMapper.specialKeyMap[116] == "ArrowUp")    // fn+↑ → Page Up
        #expect(KeyCodeMapper.specialKeyMap[121] == "ArrowDown")  // fn+↓ → Page Down
        #expect(KeyCodeMapper.specialKeyMap[117] == "Delete")     // fn+delete → Fwd Delete
    }

    /// 组合键 ID：修饰键按 macOS 菜单顺序 ⌃⌥⇧⌘ 拼接 + 主键键帽文字。
    @Test func testComboIDBuilding() {
        #expect(ComboKeyBuilder.comboID(modifiers: [.command], keyID: "C") == "⌘C")
        #expect(ComboKeyBuilder.comboID(modifiers: [.shift, .command], keyID: "Digit3") == "⇧⌘3")
        #expect(ComboKeyBuilder.comboID(modifiers: [.command, .control, .option],
                                               keyID: "Delete") == "⌃⌥⌘Delete")
        #expect(ComboKeyBuilder.comboID(modifiers: [.command, .shift], keyID: "V") == "⇧⌘V")
        // 输入顺序无关，输出顺序确定。
        #expect(ComboKeyBuilder.comboID(modifiers: [.command, .control, .option, .shift], keyID: "A") == ComboKeyBuilder.comboID(modifiers: [.shift, .command, .option, .control], keyID: "A"))
        #expect(ComboKeyBuilder.comboID(modifiers: [.command, .control, .option, .shift], keyID: "A") == "⌃⌥⇧⌘A")
        // 主键显示用键帽文字；Space 无键帽文字，回退键位 ID。
        #expect(ComboKeyBuilder.comboID(modifiers: [.command], keyID: "Space") == "⌘Space")
    }
}
