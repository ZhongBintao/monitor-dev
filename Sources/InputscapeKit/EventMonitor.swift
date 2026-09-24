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
///
/// 触控板手势覆盖（2026-09 触控板增强，参考 SO #1383528 / rift 的公开路线）：
/// - tap 掩码扩到全事件（kCGEventMaskForAllEvents，listen-only）——
///   系统不向 NSEvent 全局监听投递手势事件，但对 CGEventTap 会按原始
///   数值类型投递（CGEventType 无手势命名 case，与 NSEvent 手势类型
///   一一对应：rotate 18 / beginGesture 19 / endGesture 20 / gesture 29 /
///   magnify 30 / swipe 31 / smartMagnify 32 / pressure 34）；
/// - 回调内按 rawValue 过滤后经 NSEvent(cgEvent:) 转换，非手势事件
///   只做一次集合查找（纳秒级），all-events 频率开销可忽略；
/// - 缩放 / 旋转按 GestureSessionTracker 在手势会话结束时结算
///   （一次手势计 1 次）；滚动会话用 scrollWheel 自带 phase 判定
///   （began→ended 一次接触计 1 次，动量与滚轮鼠标不计）；
/// - 点击压力（kCGMouseEventPressure）按轻/中/深三档统计，
///   深按档阈值与 Force Touch 计数联动。
public final class EventMonitor: @unchecked Sendable {

    public struct Handlers: Sendable {
        /// 任意键盘按下（普通键、修饰键、特殊键、媒体键），参数为键位 ID。
        public var onKey: (@Sendable (String) -> Void)? = nil
        /// 组合键和弦（修饰键按住时按下普通键），参数为组合 ID 与主键键位 ID。
        public var onCombo: (@Sendable (String, String) -> Void)? = nil
        /// 键盘释放（实时页"按下中 → 已松开"即时反馈）。
        public var onKeyUp: (@Sendable (String) -> Void)? = nil
        /// 垂直滚动（deltaY 符号 = 内容移动方向：>0 内容下移）。
        public var onScroll: (@Sendable (Double) -> Void)? = nil
        /// 横向滚动（deltaX 符号 = 内容移动方向：>0 内容右移）。
        public var onScrollHorizontal: (@Sendable (Double) -> Void)? = nil
        /// 一次触控板滚动会话（手指接触滚动 → 抬起，scrollWheel phase 判定）。
        public var onScrollSession: (@Sendable () -> Void)? = nil
        public var onClick: (@Sendable () -> Void)? = nil
        public var onForceTouch: (@Sendable () -> Void)? = nil
        /// leftMouseDown 点击压力（0–1+），按轻/中/深三档入直方图。
        public var onPressure: (@Sendable (Double) -> Void)? = nil
        /// 放大（手势会话结束结算，一次手势计 1 次）。
        public var onZoomIn: (@Sendable () -> Void)? = nil
        /// 缩小（同上）。
        public var onZoomOut: (@Sendable () -> Void)? = nil
        /// 智能缩放（双指双击）。
        public var onSmartZoom: (@Sendable () -> Void)? = nil
        /// 旋转手势（clockwise = 顺时针；符号约定待真机标定）。
        public var onRotate: (@Sendable (_ clockwise: Bool) -> Void)? = nil
        public var onSwipe: (@Sendable () -> Void)? = nil
        /// 放大手势进行中（实时页方向即时反馈；isZoomIn = true 放大）。
        public var onMagnifyLive: (@Sendable (_ isZoomIn: Bool) -> Void)? = nil
        public var onGestureStart: (@Sendable () -> Void)? = nil
        public var onGestureEnd: (@Sendable () -> Void)? = nil

        public init(onKey: (@Sendable (String) -> Void)? = nil,
                    onCombo: (@Sendable (String, String) -> Void)? = nil,
                    onKeyUp: (@Sendable (String) -> Void)? = nil,
                    onScroll: (@Sendable (Double) -> Void)? = nil,
                    onScrollHorizontal: (@Sendable (Double) -> Void)? = nil,
                    onScrollSession: (@Sendable () -> Void)? = nil,
                    onClick: (@Sendable () -> Void)? = nil,
                    onForceTouch: (@Sendable () -> Void)? = nil,
                    onPressure: (@Sendable (Double) -> Void)? = nil,
                    onZoomIn: (@Sendable () -> Void)? = nil,
                    onZoomOut: (@Sendable () -> Void)? = nil,
                    onSmartZoom: (@Sendable () -> Void)? = nil,
                    onRotate: (@Sendable (_ clockwise: Bool) -> Void)? = nil,
                    onSwipe: (@Sendable () -> Void)? = nil,
                    onMagnifyLive: (@Sendable (_ isZoomIn: Bool) -> Void)? = nil,
                    onGestureStart: (@Sendable () -> Void)? = nil,
                    onGestureEnd: (@Sendable () -> Void)? = nil) {
            self.onKey = onKey
            self.onCombo = onCombo
            self.onKeyUp = onKeyUp
            self.onScroll = onScroll
            self.onScrollHorizontal = onScrollHorizontal
            self.onScrollSession = onScrollSession
            self.onClick = onClick
            self.onForceTouch = onForceTouch
            self.onPressure = onPressure
            self.onZoomIn = onZoomIn
            self.onZoomOut = onZoomOut
            self.onSmartZoom = onSmartZoom
            self.onRotate = onRotate
            self.onSwipe = onSwipe
            self.onMagnifyLive = onMagnifyLive
            self.onGestureStart = onGestureStart
            self.onGestureEnd = onGestureEnd
        }
    }

    /// 组合键去抖：同一和弦在窗口内视为按键重复，不重复计数。
    public static let comboDebounceInterval: TimeInterval = 0.15

    // MARK: - 事件探针（诊断用）

    /// 环境变量 INPUTSCAPE_DEBUG_EVENTS=1 时，把 tap 看到的 keyDown 键码
    /// （含未映射）、全部 systemDefined 事件（含 subtype ≠ 8）与手势事件
    /// （magnify / rotate / pressure 的数值）追加到 /tmp/inputscape-events.log，
    /// 用于排查特殊功能键投递形态，兼做手势 / 压力事件的全局可达性探针
    /// （提案 §三：真机验证 .pressure 是否经 tap 全局投递）。
    /// 只记录事件字段数值，不记录字符内容或坐标。
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

    /// CGEventType 无手势事件的命名 case：手势以原始数值类型经 tap 投递，
    /// 与 NSEvent 手势类型的 rawValue 一一对应（见 AppKit NSEvent.h
    /// NSEventType 枚举与类注释）。过滤集用 NSEvent 枚举运行时取值构造，
    /// 避免硬编码出错。
    private static let gestureEventRawValues: Set<Int> = {
        let types: [NSEvent.EventType] = [.gesture, .magnify, .swipe, .rotate,
                                          .beginGesture, .endGesture,
                                          .smartMagnify, .pressure]
        return Set(types.map { Int($0.rawValue) })
    }()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keepAliveTimer: Timer?
    private let handlers: Handlers
    private let stateLock = NSLock()
    /// 当前手势会话的方向判定器（beginGesture 打开、endGesture 结算）。
    private var gestureTracker: GestureSessionTracker?
    /// 进行中的滚动会话（scrollWheel phase began → ended）。
    private var scrollSessionOpen = false
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

        // 全事件掩码（kCGEventMaskForAllEvents，listen-only）：手势事件
        // （缩放 / 旋转 / 智能缩放 / 轻扫 / 压力）没有 CGEventType 命名 case，
        // 只能全事件监听后在回调内按 rawValue 过滤（见类注释）。
        // 回调对非手势事件只做一次 switch + 集合查找，开销纳秒级。
        let mask: CGEventMask = ~0

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
        isRunning = false
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
            handleScrollWheel(event)

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if type == .leftMouseDown {
                let pressure = event.getDoubleValueField(.mouseEventPressure)
                // 深按档阈值与 Force Touch 计数联动（PressureTier.deepThreshold）。
                if pressure >= PressureTier.deepThreshold {
                    handlers.onForceTouch?()
                } else {
                    handlers.onClick?()
                }
                // 三档压力直方图（引擎侧按 Force Touch 开关门控采集）。
                handlers.onPressure?(pressure)
            } else {
                handlers.onClick?()
            }

        case .tapDisabledByTimeout, .tapDisabledByUserInput:
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
                return
            }
            // 手势事件：无命名 CG 枚举，按原始数值过滤后转 NSEvent 处理。
            handlePossibleGestureEvent(type: type, event: event)
        }
    }

    // MARK: - 滚动（垂直 / 横向 / 会话）

    private func handleScrollWheel(_ event: CGEvent) {
        let deltaY = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
        if deltaY != 0 { handlers.onScroll?(deltaY) }
        let deltaX = event.getDoubleValueField(.scrollWheelEventDeltaAxis2)
        if deltaX != 0 { handlers.onScrollHorizontal?(deltaX) }

        // 滚动会话：scrollWheel 自带 phase（AppKit NSEvent.h NSEventPhase 位值：
        // began 0x1 / stationary 0x2 / changed 0x4 / ended 0x8 / cancelled 0x10 /
        // mayBegin 0x20）。触控板滚动从 mayBegin/began 开始、ended/cancelled
        // 结束，一次接触计 1 次会话；动量阶段（phase = 0）与滚轮鼠标（无 phase）
        // 不计。不用 beginGesture→endGesture 判定：捏合等手势也走 beginGesture，
        // 会把缩放误计为滚动会话。
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        guard phase != 0 else { return }
        var sessionEnded = false
        stateLock.lock()
        if phase & 0x18 != 0 {                       // ended / cancelled
            if scrollSessionOpen {
                scrollSessionOpen = false
                sessionEnded = true
            }
        } else if phase & 0x21 != 0 {                // mayBegin / began
            if scrollSessionOpen {
                // 上一会话的 ended 事件丢失：先结算再开新会话。
                sessionEnded = true
            }
            scrollSessionOpen = true
        }
        stateLock.unlock()
        if sessionEnded { handlers.onScrollSession?() }
    }

    // MARK: - 手势事件（tap 投递的原始数值类型 → NSEvent）

    private func handlePossibleGestureEvent(type: CGEventType, event: CGEvent) {
        let raw = Int(type.rawValue)
        guard Self.gestureEventRawValues.contains(raw),
              let nsEvent = NSEvent(cgEvent: event) else { return }
        if Self.debugEvents {
            switch nsEvent.type {
            case .magnify:
                Self.debugLog("gesture magnify magnification=\(nsEvent.magnification)")
            case .rotate:
                Self.debugLog("gesture rotate rotation=\(nsEvent.rotation)")
            case .pressure:
                Self.debugLog("gesture pressure pressure=\(nsEvent.pressure) stage=\(nsEvent.stage)")
            default:
                Self.debugLog("gesture raw=\(raw) nsType=\(nsEvent.type.rawValue)")
            }
        }
        handleGestureEvent(nsEvent)
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

    // MARK: - 手势会话（缩放 / 旋转 / 智能缩放 / 轻扫）

    private func handleGestureEvent(_ event: NSEvent) {
        switch event.type {
        case .beginGesture:
            // 防 endGesture 丢失：开新会话前先结算悬挂的旧会话。
            let dangling = finalizeGesture()
            stateLock.lock()
            gestureTracker = GestureSessionTracker()
            stateLock.unlock()
            for kind in dangling { handlers.dispatch(kind) }
            handlers.onGestureStart?()

        case .magnify:
            let delta = event.magnification
            stateLock.lock()
            gestureTracker?.addMagnification(delta)
            let direction = gestureTracker?.magnifyDirectionSoFar
            stateLock.unlock()
            if let direction { handlers.onMagnifyLive?(direction) }

        case .rotate:
            stateLock.lock()
            gestureTracker?.addRotation(Double(event.rotation))
            stateLock.unlock()

        case .smartMagnify:
            handlers.onSmartZoom?()

        case .swipe:
            handlers.onSwipe?()

        case .endGesture:
            for kind in finalizeGesture() {
                handlers.dispatch(kind)
            }
            handlers.onGestureEnd?()

        default:
            break
        }
    }

    /// 结算当前手势会话（缩放 / 旋转方向类别），返回后置空。
    private func finalizeGesture() -> [TrackpadOperationKind] {
        stateLock.lock()
        let kinds = gestureTracker?.finish() ?? []
        gestureTracker = nil
        stateLock.unlock()
        return kinds
    }
}

// MARK: - Handlers 手势类别派发

extension EventMonitor.Handlers {
    /// 把 GestureSessionTracker 结算出的方向类别派发到对应回调。
    fileprivate func dispatch(_ kind: TrackpadOperationKind) {
        switch kind {
        case .zoomIn: onZoomIn?()
        case .zoomOut: onZoomOut?()
        case .rotateCW: onRotate?(true)
        case .rotateCCW: onRotate?(false)
        default: break
        }
    }
}
