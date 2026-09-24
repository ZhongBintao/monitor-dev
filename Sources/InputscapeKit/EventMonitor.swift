import Foundation
import CoreGraphics
import AppKit

// MARK: - 权限

public struct PermissionStatus: Sendable, Equatable {
    /// 输入监听（Input Monitoring，CGEventTap 监听键盘所必需）。
    public var listenEvent: Bool
    /// 辅助功能（Accessibility，全局鼠标 / 手势事件所需）。
    public var accessibility: Bool

    public var granted: Bool { listenEvent && accessibility }
    public var denied: Bool { !granted }

    public static let unknown = PermissionStatus(listenEvent: false, accessibility: false)
}

public enum PermissionCenter {

    public static func currentStatus() -> PermissionStatus {
        PermissionStatus(
            listenEvent: CGPreflightListenEventAccess(),
            accessibility: AXIsProcessTrusted()
        )
    }

    /// 触发系统授权弹窗，返回当前是否已授权。
    @discardableResult
    public static func requestAccess() -> PermissionStatus {
        _ = CGRequestListenEventAccess()
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        return currentStatus()
    }
}

// MARK: - 事件监听器

/// 全局输入监听适配层。
///
/// 隐私红线（设计文档 §10）：
/// - 只输出物理键位 ID、聚合后的操作类别与「修饰键按住 + 普通键按下」
///   的和弦快照（组合键），从不读取 keyboardEventUnicodeString /
///   charactersIgnoringModifiers；
/// - 不读取鼠标 / 触控板坐标，不记录事件时间序列。
///
/// 键盘事件覆盖（对齐系统实际行为，参考 KeyCastr / MediaKeyTap 的公开方案）：
/// - keyDown：普通键 + Apple Silicon 特殊键码（130→F3、131→F4）；
/// - flagsChanged：command / control / option / shift / fn / caps 单独按下；
/// - systemDefined(subtype 8)：默认设置下物理 F1/F2/F7–F12 的媒体事件
///   （亮度 / 播放控制 / 音量），映射回物理键位 ID 统计。
public final class EventMonitor: @unchecked Sendable {

    public struct Handlers: Sendable {
        /// 任意键盘按下（普通键、修饰键、特殊键、媒体键），参数为键位 ID。
        public var onKey: (@Sendable (String) -> Void)? = nil
        /// 组合键和弦（修饰键按住时按下普通键），参数为组合 ID 与主键键位 ID。
        public var onCombo: (@Sendable (String, String) -> Void)? = nil
        /// 键盘释放（实时页"按下中 → 已松开"即时反馈）。
        public var onKeyUp: (@Sendable (String) -> Void)? = nil
        public var onScroll: (@Sendable (Double) -> Void)? = nil        // deltaY 符号：>0 上滚
        public var onClick: (@Sendable () -> Void)? = nil
        public var onForceTouch: (@Sendable () -> Void)? = nil
        public var onZoom: (@Sendable () -> Void)? = nil
        public var onSwipe: (@Sendable () -> Void)? = nil
        public var onGestureStart: (@Sendable () -> Void)? = nil
        public var onMagnifyActive: (@Sendable () -> Void)? = nil
        public var onGestureEnd: (@Sendable () -> Void)? = nil

        public init(onKey: (@Sendable (String) -> Void)? = nil,
                    onCombo: (@Sendable (String, String) -> Void)? = nil,
                    onKeyUp: (@Sendable (String) -> Void)? = nil,
                    onScroll: (@Sendable (Double) -> Void)? = nil,
                    onClick: (@Sendable () -> Void)? = nil,
                    onForceTouch: (@Sendable () -> Void)? = nil,
                    onZoom: (@Sendable () -> Void)? = nil,
                    onSwipe: (@Sendable () -> Void)? = nil,
                    onGestureStart: (@Sendable () -> Void)? = nil,
                    onMagnifyActive: (@Sendable () -> Void)? = nil,
                    onGestureEnd: (@Sendable () -> Void)? = nil) {
            self.onKey = onKey
            self.onCombo = onCombo
            self.onKeyUp = onKeyUp
            self.onScroll = onScroll
            self.onClick = onClick
            self.onForceTouch = onForceTouch
            self.onZoom = onZoom
            self.onSwipe = onSwipe
            self.onGestureStart = onGestureStart
            self.onMagnifyActive = onMagnifyActive
            self.onGestureEnd = onGestureEnd
        }
    }

    /// Force Touch 判定阈值（kCGMouseEventPressure > 1.0 视为深按；经验值）。
    public static let forceTouchPressureThreshold: Double = 1.5

    /// 组合键去抖：同一和弦在窗口内视为按键重复，不重复计数。
    public static let comboDebounceInterval: TimeInterval = 0.15

    // MARK: - 事件探针（诊断用）

    /// 环境变量 INPUTSCAPE_DEBUG_EVENTS=1 时，把 tap 看到的 keyDown 键码
    /// （含未映射）与全部 systemDefined 事件（含 subtype ≠ 8）追加到
    /// /tmp/inputscape-events.log，用于排查特殊功能键（F3/F5/F6 等）
    /// 的事件投递形态。只记录键码与事件字段，不记录字符内容。
    private static let debugEvents =
        ProcessInfo.processInfo.environment["INPUTSCAPE_DEBUG_EVENTS"] == "1"
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/inputscape-events.log")
    private static let debugLock = NSLock()

    private static func debugLog(_ line: String) {
        guard debugEvents else { return }
        debugLock.lock(); defer { debugLock.unlock() }
        let text = "\(String(format: "%.3f", Date().timeIntervalSince1970)) \(line)\n"
        let data = Data(text.utf8)
        if let handle = try? FileHandle(forWritingTo: debugLogURL) {
            defer { try? handle.close() }
            handle.seekToEndOfFile()
            handle.write(data)
        } else {
            try? data.write(to: debugLogURL)
        }
    }

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keepAliveTimer: Timer?
    private var monitors: [NSObjectProtocol] = []
    private let handlers: Handlers
    private let stateLock = NSLock()
    private var gestureActive = false
    private var magnifySeenInGesture = false
    private var lastFlags: CGEventFlags = []
    private var capsLockPressed = false
    private var lastComboID: String?
    private var lastComboAt = Date.distantPast

    public private(set) var isRunning = false

    public init(handlers: Handlers) {
        self.handlers = handlers
    }

    deinit { stop() }

    // MARK: - 启停

    /// 尝试创建事件 tap；失败（权限不足等）返回 false。
    @discardableResult
    public func start() -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard !isRunning else { return true }

        let mask: CGEventMask = (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)
            | (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.rightMouseDown.rawValue)
            | (1 << CGEventType.otherMouseDown.rawValue)
            | (1 << CGEventType.scrollWheel.rawValue)
            | (1 << 14) // kCGEventSystemDefined：媒体键（亮度 / 播放 / 音量）

        let callback: CGEventTapCallBack = { proxy, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            let monitor = Unmanaged<EventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleTapEvent(type: type, event: event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .listenOnly,
                                          eventsOfInterest: mask,
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            return false
        }
        self.tap = tap
        self.runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFMachPortSetInvalidationCallBack(tap) { machPort, _ in
            guard let machPort else { return }
            CGEvent.tapEnable(tap: machPort, enable: false)
        }

        // 事件 source 必须挂在主 run loop：
        // 会话级 tap 存在时，HIToolbox 会把 caps（中英文切换）长按等
        // 辅助处理的 timer 装到 tap 所在的 run loop 上，其内部
        // dispatch_assert_queue 要求主队列——挂在后台线程会导致
        // 按住 caps 直接 SIGTRAP 崩溃（实测崩溃栈
        // TSMAdjustCapsLockPressAndHold → dispatch_assert_queue_fail）。
        // 回调本身只做映射与派发，主线程开销可忽略。
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        // 唤醒被系统禁用的 tap（超时保护）。
        let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self, let tap = self.tap else { return }
            if !CGEvent.tapIsEnabled(tap: tap) {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.keepAliveTimer = timer

        // 手势事件走 NSEvent 全局监听（公开接口；部分手势系统层面不投递全局监听，
        // 此时缩放 / 滑动计数保持为 0，属公开接口已知边界）。
        DispatchQueue.main.async { [weak self] in
            self?.installGestureMonitors()
        }

        isRunning = true
        return true
    }

    public func stop() {
        stateLock.lock(); defer { stateLock.unlock() }
        guard isRunning else { return }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            if let source = runLoopSource {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            }
        }
        keepAliveTimer?.invalidate()
        tap = nil
        runLoopSource = nil
        keepAliveTimer = nil
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for m in self.monitors {
                NSEvent.removeMonitor(m)
            }
            self.monitors.removeAll()
        }
        isRunning = false
    }

    private func installGestureMonitors() {
        let gestureMask: NSEvent.EventTypeMask = [.gesture, .magnify, .smartMagnify, .swipe,
                                                  .beginGesture, .endGesture]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: gestureMask,
                                                           handler: { [weak self] event in
            self?.handleGestureEvent(event)
        }) as? NSObjectProtocol {
            monitors.append(monitor)
        }
    }

    // MARK: - 修饰键位 → 事件标志位

    private func flagBit(forModifierKeyID keyID: String) -> CGEventFlags? {
        switch keyID {
        case "CommandLeft", "CommandRight": return .maskCommand
        case "ControlLeft": return .maskControl
        case "OptionLeft", "OptionRight": return .maskAlternate
        case "ShiftLeft", "ShiftRight": return .maskShift
        case "Fn": return .maskSecondaryFn
        case "CapsLock": return .maskAlphaShift
        default: return nil
        }
    }

    private func comboModifiers(in flags: CGEventFlags) -> [ComboModifier] {
        var mods: [ComboModifier] = []
        if flags.contains(.maskControl) { mods.append(.control) }
        if flags.contains(.maskAlternate) { mods.append(.option) }
        if flags.contains(.maskShift) { mods.append(.shift) }
        if flags.contains(.maskCommand) { mods.append(.command) }
        return mods
    }

    // MARK: - 事件分类（只取计数所需字段）

    fileprivate func handleTapEvent(type: CGEventType, event: CGEvent) {
        switch type {
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let code = UInt64(bitPattern: keyCode)
            if Self.debugEvents {
                let mapped = KeyCodeMapper.keyID(for: code) ?? KeyCodeMapper.specialKeyMap[code]
                Self.debugLog("keyDown code=\(keyCode) mapped=\(mapped.map { "'\($0)'" } ?? "nil")")
            }
            let flags = event.flags

            // Apple Silicon 特殊键码（F3 调度中心 / F4 启动台或聚焦）。
            if let special = KeyCodeMapper.specialKeyMap[code] {
                handlers.onKey?(special)
                return
            }
            guard let keyID = KeyCodeMapper.keyID(for: code) else { return }

            // 组合键：修饰键按住时按下普通键 → 和弦快照。
            let mods = comboModifiers(in: flags)
            if !mods.isEmpty, flagBit(forModifierKeyID: keyID) == nil {
                let comboID = ComboKeyBuilder.comboID(modifiers: mods, keyID: keyID)
                if !isComboRepeat(comboID) {
                    handlers.onCombo?(comboID, keyID)
                }
            }
            handlers.onKey?(keyID)

        case .keyUp:
            // 松开即时反馈：映射键位 ID（含特殊键码）交给实时层清除"按下中"。
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let code = UInt64(bitPattern: keyCode)
            if let keyID = KeyCodeMapper.specialKeyMap[code] ?? KeyCodeMapper.keyID(for: code) {
                handlers.onKeyUp?(keyID)
            }

        case .flagsChanged:
            // 修饰键的按下与释放都走 flagsChanged（没有 keyUp）。
            // 按下/释放用「该键标志位是否新增/移除」判定（KeyCastr 模式）；
            // 释放必须回传 onKeyUp，否则实时层的"按下中"永久残留。
            // CapsLock 特殊：按下与释放的 flags 完全相同（LED 锁定态），
            // 用事件交替判定（按一次/松一次各来一个事件）。
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let code = UInt64(bitPattern: keyCode)
            let flags = event.flags
            defer {
                stateLock.lock()
                lastFlags = flags
                stateLock.unlock()
            }
            guard let keyID = KeyCodeMapper.keyID(for: code),
                  let bit = flagBit(forModifierKeyID: keyID) else { return }

            if keyID == "CapsLock" {
                let nowPressed: Bool
                stateLock.lock()
                capsLockPressed.toggle()
                nowPressed = capsLockPressed
                stateLock.unlock()
                if nowPressed {
                    handlers.onKey?(keyID)
                } else {
                    handlers.onKeyUp?(keyID)
                }
                return
            }

            let wasSet = lastFlags.contains(bit)
            let isSet = flags.contains(bit)
            if isSet && !wasSet {
                handlers.onKey?(keyID)
            } else if wasSet && !isSet {
                handlers.onKeyUp?(keyID)
            }

        case .scrollWheel:
            let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            if delta != 0 { handlers.onScroll?(delta) }

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            let pressure = event.getDoubleValueField(.mouseEventPressure)
            if type == .leftMouseDown, pressure >= Self.forceTouchPressureThreshold {
                handlers.onForceTouch?()
            } else {
                handlers.onClick?()
            }

        case .tapDisabledByTimeout:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }

        default:
            // 媒体键：systemDefined（14）+ subtype 8，data1 位域见 KeyCodeMapper。
            // 按下（keyState 0xA）与释放（0xB）是同一事件的两种状态：
            // 按下计数并点亮，释放熄灭——与普通键 keyDown/keyUp 行为对称。
            // 此前只处理按下帧，实时层的按下状态会永久残留（实测缺陷）。
            if type.rawValue == 14 {
                // 探针：记录全部 systemDefined 事件（含 subtype ≠ 8），
                // 用于排查特殊功能键（F3/F5/F6）的实际投递形态
                let nsEvent = NSEvent(cgEvent: event)
                if Self.debugEvents {
                    if let nsEvent, nsEvent.type == .systemDefined {
                        let data1 = Int64(nsEvent.data1)
                        let keyType = Int((data1 & 0xFFFF0000) >> 16)
                        let keyFlags = Int(data1 & 0x0000FFFF)
                        Self.debugLog("systemDefined subtype=\(nsEvent.subtype.rawValue) data1=0x\(String(data1, radix: 16)) keyType=\(keyType) keyFlags=0x\(String(keyFlags, radix: 16))")
                    } else {
                        Self.debugLog("systemDefined nsConv=nil rawType=\(type.rawValue)")
                    }
                }
                if let nsEvent, nsEvent.type == .systemDefined, nsEvent.subtype.rawValue == 8 {
                    let data1 = Int64(nsEvent.data1)
                    guard !KeyCodeMapper.isMediaKeyRepeat(data1),
                          let keyID = KeyCodeMapper.keyID(forMediaData1: data1) else { return }
                    if KeyCodeMapper.isMediaKeyDown(data1) {
                        handlers.onKey?(keyID)
                    } else {
                        handlers.onKeyUp?(keyID)
                    }
                }
            }
        }
    }

    private func isComboRepeat(_ comboID: String) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        let now = Date()
        defer {
            lastComboID = comboID
            lastComboAt = now
        }
        return lastComboID == comboID && now.timeIntervalSince(lastComboAt) < Self.comboDebounceInterval
    }

    fileprivate func handleGestureEvent(_ event: NSEvent) {
        switch event.type {
        case .beginGesture:
            stateLock.lock()
            gestureActive = true
            magnifySeenInGesture = false
            stateLock.unlock()
            handlers.onGestureStart?()

        case .magnify:
            stateLock.lock()
            magnifySeenInGesture = gestureActive
            stateLock.unlock()
            if gestureActive { handlers.onMagnifyActive?() }

        case .smartMagnify:
            handlers.onZoom?()

        case .swipe:
            handlers.onSwipe?()

        case .endGesture:
            stateLock.lock()
            let wasZoom = gestureActive && magnifySeenInGesture
            gestureActive = false
            magnifySeenInGesture = false
            stateLock.unlock()
            if wasZoom { handlers.onZoom?() }
            handlers.onGestureEnd?()

        default:
            break
        }
    }
}
