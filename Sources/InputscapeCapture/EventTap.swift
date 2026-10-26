import Foundation
import CoreGraphics
import AppKit
import InputscapeCore

/// 事件 tap 向上层报告的特征事件（不含字符、坐标或事件序列）。
public enum TapEvent: Sendable {
    case keyDown(keyID: String, isRepeat: Bool)
    case keyUp(keyID: String)
    case shortcut(combo: String)
    /// 鼠标按下：button 0 左 / 1 右 / 2 其他；uptime 用于和触控板压力对齐
    case mouseDown(button: Int, uptime: Double)
    /// 像素滚动（连续设备）；momentum = 惯性阶段
    case scroll(dx: Double, dy: Double, momentum: Bool)
    case pointerMoved
}

/// 全局输入监听：会话级、只监听（listen-only）、挂在主 run loop。
///
/// 隐私：只读键码、修饰键位、按钮号与滚动像素量；从不读取
/// keyboardEventUnicodeString 或鼠标坐标。
public final class EventTap: @unchecked Sendable {

    public typealias Handler = (TapEvent) -> Void

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var keepAlive: Timer?
    private let handler: Handler

    private var lastFlags: UInt64 = 0
    private var capsLockToggle = false

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    public var isRunning: Bool { tap != nil }

    // MARK: 启停

    @discardableResult
    public func start() -> Bool {
        guard tap == nil else { return true }
        let types: [CGEventType] = [.keyDown, .keyUp, .flagsChanged, .scrollWheel,
                                    .leftMouseDown, .rightMouseDown, .otherMouseDown,
                                    .mouseMoved, .leftMouseDragged]
        var mask: CGEventMask = types.reduce(0) { $0 | (1 << CGEventMask($1.rawValue)) }
        mask |= 1 << 14  // NX_SYSDEFINED：F 行媒体键

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
            }
            return Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .listenOnly, eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        // 必须挂主 run loop：caps 长按切换输入法时 HIToolbox 要求主队列（v1 实测崩溃）
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            guard let tap = self?.tap, !CGEvent.tapIsEnabled(tap: tap) else { return }
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        keepAlive = timer
        lastFlags = 0
        capsLockToggle = false
        return true
    }

    public func stop() {
        keepAlive?.invalidate()
        keepAlive = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    // MARK: 分类

    /// 设备相关的修饰键位（IOKit NX_DEVICE*KEYMASK）：可区分左右，且同侧按住时另一侧仍能被识别。
    static let deviceModifierBits: [String: UInt64] = [
        "ControlLeft": 0x0000_0001,
        "ShiftLeft": 0x0000_0002,
        "ShiftRight": 0x0000_0004,
        "CommandLeft": 0x0000_0008,
        "CommandRight": 0x0000_0010,
        "OptionLeft": 0x0000_0020,
        "OptionRight": 0x0000_0040,
        "Fn": CGEventFlags.maskSecondaryFn.rawValue
    ]

    static func modifiers(in flags: CGEventFlags) -> Set<ComboModifier> {
        var mods: Set<ComboModifier> = []
        if flags.contains(.maskControl) { mods.insert(.control) }
        if flags.contains(.maskAlternate) { mods.insert(.option) }
        if flags.contains(.maskShift) { mods.insert(.shift) }
        if flags.contains(.maskCommand) { mods.insert(.command) }
        return mods
    }

    private func keyID(for event: CGEvent) -> String? {
        let code = UInt64(bitPattern: event.getIntegerValueField(.keyboardEventKeycode))
        return KeyCodeMapper.specialKeyMap[code] ?? KeyCodeMapper.keyID(for: code)
    }

    private func handle(type: CGEventType, event: CGEvent) {
        let lab = SignalLab.shared
        switch type {
        case .keyDown:
            guard let id = keyID(for: event) else { return }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if lab.isActive {
                let now = ProcessInfo.processInfo.systemUptime
                lab.noteKeyDown(keyID: id, isRepeat: isRepeat, at: now)
                lab.noteEventTimestamp(raw: event.timestamp, at: now)
            }
            handler(.keyDown(keyID: id, isRepeat: isRepeat))
            if !isRepeat, let combo = ShortcutRule.comboID(modifiers: Self.modifiers(in: event.flags), keyID: id) {
                handler(.shortcut(combo: combo))
            }

        case .keyUp:
            if let id = keyID(for: event) { handler(.keyUp(keyID: id)) }

        case .flagsChanged:
            let raw = event.flags.rawValue
            defer { lastFlags = raw }
            guard let id = keyID(for: event) else { return }
            if id == "CapsLock" {
                // 按下与松开各来一次且标志相同：按事件交替判定
                capsLockToggle.toggle()
                handler(capsLockToggle ? .keyDown(keyID: id, isRepeat: false) : .keyUp(keyID: id))
                return
            }
            guard let bit = Self.deviceModifierBits[id] else { return }
            let isDown = raw & bit != 0
            let wasDown = lastFlags & bit != 0
            if isDown && !wasDown {
                handler(.keyDown(keyID: id, isRepeat: false))
            } else if !isDown && wasDown {
                handler(.keyUp(keyID: id))
            }

        case .scrollWheel:
            guard event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0 else { return }
            let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
            let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
            guard dx != 0 || dy != 0 else { return }
            let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
            handler(.scroll(dx: dx, dy: dy, momentum: momentum))

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let button = type == .leftMouseDown ? 0 : (type == .rightMouseDown ? 1 : 2)
            let now = ProcessInfo.processInfo.systemUptime
            lab.noteMouseDown(button: button, at: now)
            lab.noteEventTimestamp(raw: event.timestamp, at: now)
            handler(.mouseDown(button: button, uptime: now))

        case .mouseMoved, .leftMouseDragged:
            handler(.pointerMoved)

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        default:
            // F 行媒体键：systemDefined(14) subtype 8，data1 高 16 位为 NX_KEYTYPE
            guard type.rawValue == 14, let ns = NSEvent(cgEvent: event),
                  ns.type == .systemDefined, ns.subtype.rawValue == 8 else { return }
            let data1 = Int64(ns.data1)
            guard let id = KeyCodeMapper.keyID(forMediaData1: data1) else { return }
            if KeyCodeMapper.isMediaKeyDown(data1) {
                handler(.keyDown(keyID: id, isRepeat: KeyCodeMapper.isMediaKeyRepeat(data1)))
            } else {
                handler(.keyUp(keyID: id))
            }
        }
    }
}
