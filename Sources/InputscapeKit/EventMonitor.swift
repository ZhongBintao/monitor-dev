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
/// 触控板手势覆盖（2026-09-24 收缩口径：只保留官方事件直接计数）：
/// - tap 掩码为全事件（kCGEventMaskForAllEvents，listen-only）——
///   系统不向 NSEvent 全局监听投递手势事件，但对 CGEventTap 会按原始
///   数值类型投递（CGEventType 无手势命名 case，与 NSEvent 手势类型
///   一一对应：smartMagnify 32 / swipe 31，见 AppKit NSEvent.h）；
/// - 只消费 smartMagnify（智能缩放，双指双击）与 swipe（三指轻扫）：
///   收到事件计 1 次，附短不应期吸收疑似重复投递（GestureRefractoryGate）；
///   缩放分向 / 旋转 / 横滚等自定义口径已于 2026-09-24 按用户决策删除；
/// - 回调内按 rawValue 过滤（非手势事件只做一次集合查找），
///   all-events 频率开销可忽略；
/// - 滚动（scrollWheel）做会话化去抖（ScrollSessionAccumulator）：间隔
///   < 250ms 的连续事件并入同一会话，会话结束按主导方向计 1 次上/下滚，
///   总位移低于噪声门限的微动会话丢弃——一次滑动 = 1 次计数，不再逐事件；
/// - 点击压力（kCGMouseEventPressure）按轻/重两档入直方图，
///   Force Touch 深按判定阈值独立标定、禁止联动。
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
        public var onClick: (@Sendable () -> Void)? = nil
        public var onForceTouch: (@Sendable () -> Void)? = nil
        /// leftMouseDown 点击压力（0–1+），按轻/中/深三档入直方图。
        public var onPressure: (@Sendable (Double) -> Void)? = nil
        /// 智能缩放（双指双击，官方 smartMagnify 事件直计）。
        public var onSmartZoom: (@Sendable () -> Void)? = nil
        /// 三指轻扫（官方 swipe 事件直计）。
        public var onSwipe: (@Sendable () -> Void)? = nil

        public init(onKey: (@Sendable (String) -> Void)? = nil,
                    onCombo: (@Sendable (String, String) -> Void)? = nil,
                    onKeyUp: (@Sendable (String) -> Void)? = nil,
                    onScroll: (@Sendable (Double) -> Void)? = nil,
                    onClick: (@Sendable () -> Void)? = nil,
                    onForceTouch: (@Sendable () -> Void)? = nil,
                    onPressure: (@Sendable (Double) -> Void)? = nil,
                    onSmartZoom: (@Sendable () -> Void)? = nil,
                    onSwipe: (@Sendable () -> Void)? = nil) {
            self.onKey = onKey
            self.onCombo = onCombo
            self.onKeyUp = onKeyUp
            self.onScroll = onScroll
            self.onClick = onClick
            self.onForceTouch = onForceTouch
            self.onPressure = onPressure
            self.onSmartZoom = onSmartZoom
            self.onSwipe = onSwipe
        }
    }

    /// Force Touch 深按判定阈值（kCGMouseEventPressure，点击瞬间口径）。
    /// 与手指压力分档（PressureTier，MTTouch 连续压力口径）值域不同，独立标定；
    /// 经验值 0.9，待 INPUTSCAPE_DEBUG_EVENTS 探针真机校准。
    public static let forceTouchClickThreshold: Double = 0.9

    /// 滚动会话静默间隔（秒）：连续 scrollWheel 事件间隔超过该值即开新会话。
    /// 惯性 momentum 事件间隔 < 16ms 自然并入会话尾。待真机标定。
    public static let scrollSessionGap: TimeInterval = 0.25
    /// 会话最小位移（|delta| 累计，行单位）：低于该值视为轻触微动噪声，丢弃。
    /// 待真机标定。
    public static let scrollMinimumDisplacement: Double = 3.0
    /// 手势事件不应期（秒）：swipe / smartZoom 同类事件窗口内只计第一次。
    /// 待真机标定。
    public static let gestureRefractoryInterval: TimeInterval = 0.3
    /// kCGScrollWheelEventScrollPhase 的 began 值（SDK 头文件实测 0x1）：
    /// 新手势开始时强制结算上一会话，防止长惯性尾巴吞掉新手势。
    private static let scrollPhaseBegan: Int64 = 0x1

    /// 组合键去抖：同一和弦在窗口内视为按键重复，不重复计数。
    public static let comboDebounceInterval: TimeInterval = 0.15

    // MARK: - 事件探针（诊断用）

    /// 环境变量 INPUTSCAPE_DEBUG_EVENTS=1 时，把 tap 看到的 keyDown 键码
    /// （含未映射）、全部 systemDefined 事件（含 subtype ≠ 8）与官方手势
    /// 事件（smartMagnify / swipe）追加到 /tmp/inputscape-events.log，
    /// 用于排查特殊功能键与手势事件的投递形态。
    /// 只记录事件字段数值，不记录字符内容或坐标。
    private static let debugEvents =
        ProcessInfo.processInfo.environment["INPUTSCAPE_DEBUG_EVENTS"] == "1"
    private static let debugLogURL = URL(fileURLWithPath: "/tmp/inputscape-events.log")
    private static let debugLock = NSLock()

    private static func debugLog(_ line: String) {
        guard debugEvents else { return }
        debugLogForProbe(line)
    }

    /// 探针日志写入口（调用方自行 env 门控；TouchpointMonitor 触点探针复用）。
    static func debugLogForProbe(_ line: String) {
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
    /// 避免硬编码出错。只收智能缩放与轻扫（官方事件直计）。
    private static let gestureEventRawValues: Set<Int> = {
        let types: [NSEvent.EventType] = [.smartMagnify, .swipe]
        return Set(types.map { Int($0.rawValue) })
    }()

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var keepAliveTimer: Timer?
    private var scrollFlushTimer: Timer?
    private let handlers: Handlers
    private let stateLock = NSLock()
    private var lastFlags: CGEventFlags = []
    private var capsLockPressed = false
    private var lastComboID: String?
    private var lastComboAt = Date.distantPast
    /// 滚动会话去抖与手势不应期（仅 tap 回调/主 run loop 访问，stateLock 守护）。
    private var scrollAccumulator = ScrollSessionAccumulator(
        gap: EventMonitor.scrollSessionGap,
        minimumDisplacement: EventMonitor.scrollMinimumDisplacement)
    private var swipeGate = GestureRefractoryGate(interval: EventMonitor.gestureRefractoryInterval)
    private var smartZoomGate = GestureRefractoryGate(interval: EventMonitor.gestureRefractoryInterval)

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

        // 重启监听时清空去抖状态（上次会话可能残留）。
        scrollAccumulator = ScrollSessionAccumulator(
            gap: Self.scrollSessionGap,
            minimumDisplacement: Self.scrollMinimumDisplacement)
        swipeGate = GestureRefractoryGate(interval: Self.gestureRefractoryInterval)
        smartZoomGate = GestureRefractoryGate(interval: Self.gestureRefractoryInterval)
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
        scrollFlushTimer?.invalidate()
        // 结算未完成的滚动会话，避免停监听时丢最后一次滚动的计数。
        if let d = scrollAccumulator.flush() {
            handlers.onScroll?(d)
        }
        swipeGate.reset()
        smartZoomGate.reset()
        tap = nil
        runLoopSource = nil
        keepAliveTimer = nil
        scrollFlushTimer = nil
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
            let delta = event.getDoubleValueField(.scrollWheelEventDeltaAxis1)
            guard delta != 0 else { break }
            // CGEventTimestamp 单位为纳秒 → 换算秒（与会话间隔统一量纲）。
            let t = Double(event.timestamp) / 1_000_000_000
            var emitted: Double?
            stateLock.lock()
            // 新手势开始（phase began）强制结算上一会话，防止惯性尾巴吞并新手势。
            if event.getIntegerValueField(.scrollWheelEventScrollPhase) == Self.scrollPhaseBegan {
                emitted = scrollAccumulator.flush()
            }
            // 间隔超阈值时 accept 内部先结算上一会话再并入本事件。
            if let closed = scrollAccumulator.accept(delta: delta, at: t) { emitted = closed }
            stateLock.unlock()
            // 会话结束才投递一次：+1 = 内容下移 / -1 = 内容上移
            // （手指方向换算仍由聚合层按自然滚动设置处理）。
            if let d = emitted { handlers.onScroll?(d) }
            scheduleScrollFlush()

        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            if type == .leftMouseDown {
                let pressure = event.getDoubleValueField(.mouseEventPressure)
                if Self.debugEvents {
                    Self.debugLog("clickPressure pressure=\(pressure)")
                }
                // 深按判定（kCGMouseEventPressure 值域独立标定）。
                if pressure >= Self.forceTouchClickThreshold {
                    handlers.onForceTouch?()
                } else {
                    handlers.onClick?()
                }
                // 点击瞬间压力样本（探针用途；强度分布统计已改用
                // MTTouch 手指连续压力——该字段多数触控板不随力度变化）。
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
            // 官方手势事件（智能缩放 / 轻扫）：无命名 CG 枚举，
            // 按原始数值过滤后转 NSEvent 处理。
            handlePossibleGestureEvent(type: type, event: event)
        }
    }

    // MARK: - 滚动会话结算

    /// 会话静默超时兜底：停止滚动后没有后续事件时，由该一次性 Timer
    /// （延迟 = 会话间隔）结算并投递会话方向。每次滚动事件重排。
    /// 仅在主 run loop 调用（tap 回调本就挂在主 run loop）。
    private func scheduleScrollFlush() {
        scrollFlushTimer?.invalidate()
        let timer = Timer(timeInterval: Self.scrollSessionGap, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.stateLock.lock()
            let emitted = self.scrollAccumulator.flush()
            self.stateLock.unlock()
            if let d = emitted { self.handlers.onScroll?(d) }
        }
        RunLoop.main.add(timer, forMode: .common)
        scrollFlushTimer = timer
    }

    // MARK: - 官方手势事件（tap 投递的原始数值类型 → NSEvent）

    private func handlePossibleGestureEvent(type: CGEventType, event: CGEvent) {
        let raw = Int(type.rawValue)
        guard Self.gestureEventRawValues.contains(raw),
              let nsEvent = NSEvent(cgEvent: event) else { return }
        if Self.debugEvents {
            Self.debugLog("gesture raw=\(raw) nsType=\(nsEvent.type.rawValue)")
        }
        let t = nsEvent.timestamp
        switch nsEvent.type {
        case .smartMagnify:
            // 不应期去抖：窗口内重复投递只计第一次。
            stateLock.lock()
            let accepted = smartZoomGate.shouldAccept(at: t)
            stateLock.unlock()
            if accepted { handlers.onSmartZoom?() }
        case .swipe:
            stateLock.lock()
            let accepted = swipeGate.shouldAccept(at: t)
            stateLock.unlock()
            if accepted { handlers.onSwipe?() }
        default:
            break
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
}
