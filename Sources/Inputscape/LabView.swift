import SwiftUI
import AppKit
import InputscapeCore
import InputscapeCapture

// MARK: - Lab 模型（Phase 0 信号验证）

/// 轮询 SignalLab 快照并驱动协议录制。仅在 Lab 页可见时运行。
@MainActor
final class LabModel: ObservableObject {

    struct Result {
        let protocolID: String
        let verdict: LabEvaluation.Verdict
        let pressure: LabEvaluation.SignalLevels?
        let capacitance: LabEvaluation.SignalLevels?
        let fixtureURL: URL?
        let saveError: String?
    }

    @Published private(set) var snapshot: LabSnapshot?
    @Published private(set) var running: LabProtocol?
    @Published private(set) var stepIndex = 0
    @Published private(set) var stepRemaining = 0
    @Published private(set) var results: [String: Result] = [:]

    /// P8：当前输入源、本次 Lab 期间见过的输入源（按首次出现排序），
    /// 以及切换通知次数 vs 轮询发现的切换次数（两者一致 = 通知可靠）。
    @Published private(set) var inputSource: InputSourceInfo?
    @Published private(set) var seenSources: [InputSourceInfo] = []
    @Published private(set) var sourceNotifications = 0
    @Published private(set) var sourceChangesByPoll = 0
    @Published private(set) var sourcesSavedURL: URL?

    private var pollTimer: Timer?
    private var sourceObserver: NSObjectProtocol?
    private var tickCount = 0
    private var stepEndsAt: Date?
    private var keySwallower: Any?

    private var lab: SignalLab { SignalLab.shared }
    private var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func appear() {
        lab.setActive(true)
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 1.0 / 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
        // 无文本焦点时按住 Delete 会连续 NSBeep：本窗口内吞掉不带 ⌘ 的按键。
        // listen-only 事件 tap 先于本地监听看到事件，探针不受影响。
        keySwallower = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            event.modifierFlags.contains(.command) ? event : nil
        }
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: InputSourceReader.changedNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sourceNotifications += 1
                self?.readInputSource(countChange: false)
            }
        }
        readInputSource(countChange: false)
    }

    func disappear() {
        pollTimer?.invalidate()
        pollTimer = nil
        if let keySwallower { NSEvent.removeMonitor(keySwallower) }
        keySwallower = nil
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        sourceObserver = nil
        if running != nil { onRecordingChange?(false) }
        running = nil
        lab.setActive(false)
    }

    private func tick() {
        snapshot = lab.snapshot()
        tickCount += 1
        // 1 Hz 轮询输入源：捕捉通知漏报的切换
        if tickCount % 15 == 0 { readInputSource(countChange: true) }
        guard let proto = running, let ends = stepEndsAt else { return }
        let remaining = Int(ceil(ends.timeIntervalSinceNow))
        stepRemaining = max(0, remaining)
        if remaining <= 0 { advance(proto, byUIClick: false) }
    }

    func resetKeyTotals() { lab.resetKeyTotals() }

    private func readInputSource(countChange: Bool) {
        guard let current = InputSourceReader.current() else { return }
        if current != inputSource {
            if countChange && inputSource != nil { sourceChangesByPoll += 1 }
            inputSource = current
        }
        if !seenSources.contains(current) { seenSources.append(current) }
    }

    /// 把见过的输入源存为 fixture（供 InputSourceClassifier 测试使用）。
    func saveSeenSources() {
        let directory = SignalLab.fixtureDirectory()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        let url = directory.appendingPathComponent("input-sources-\(formatter.string(from: Date())).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try encoder.encode(seenSources).write(to: url, options: .atomic)
            sourcesSavedURL = url
        } catch {
            sourcesSavedURL = nil
        }
    }

    /// 录制期间事件不进统计（由采集主管切换）
    var onRecordingChange: ((Bool) -> Void)?

    func start(_ proto: LabProtocol) {
        onRecordingChange?(true)
        running = proto
        stepIndex = 0
        lab.beginRecording(proto, at: uptime)
        enterStep(proto, 0)
    }

    /// 进入下一阶段；已是最后一阶段则结束并评估。
    /// byUIClick：由点按「下一步 / 完成」触发——该次点击不计入录制。
    func advance(_ proto: LabProtocol, byUIClick: Bool) {
        if stepIndex + 1 < proto.steps.count {
            stepIndex += 1
            enterStep(proto, stepIndex, byUIClick: byUIClick)
        } else {
            finish(proto, byUIClick: byUIClick)
        }
    }

    func cancel() {
        onRecordingChange?(false)
        _ = lab.endRecording(at: uptime)
        running = nil
        stepEndsAt = nil
    }

    private func enterStep(_ proto: LabProtocol, _ index: Int, byUIClick: Bool = false) {
        let step = proto.steps[index]
        lab.enterPhase(step.id, at: uptime, byUIClick: byUIClick)
        stepEndsAt = Date().addingTimeInterval(TimeInterval(step.seconds))
        stepRemaining = step.seconds
    }

    private func finish(_ proto: LabProtocol, byUIClick: Bool) {
        onRecordingChange?(false)
        running = nil
        stepEndsAt = nil
        guard let rec = lab.endRecording(at: uptime, byUIClick: byUIClick) else { return }
        var url: URL?
        var saveError: String?
        do { url = try SignalLab.saveFixture(rec) } catch { saveError = error.localizedDescription }
        switch proto.id {
        case LabProtocol.pressure.id:
            let r = LabEvaluation.pressure(rec)
            results[proto.id] = Result(protocolID: proto.id, verdict: r.verdict, pressure: r.pressure,
                                       capacitance: r.capacitance, fixtureURL: url, saveError: saveError)
        default:
            results[proto.id] = Result(protocolID: proto.id, verdict: LabEvaluation.keyRepeat(rec),
                                       pressure: nil, capacitance: nil, fixtureURL: url, saveError: saveError)
        }
    }
}

// MARK: - Lab 页面

struct LabView: View {
    @Environment(CaptureSupervisor.self) private var capture
    @StateObject private var lab = LabModel()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if capture.status != .recording {
                    Card {
                        Text("需要「正在观察」状态才能收到按键与触点信号。当前：\(capture.status.label)。")
                            .font(.system(size: 13)).foregroundColor(Theme.secondary)
                    }
                }
                HStack(alignment: .top, spacing: 18) {
                    keyCard
                    contactsCard
                }
                HStack(alignment: .top, spacing: 18) {
                    timestampCard
                    inputSourceCard
                }
                traceCard
                protocolsCard
            }
            .padding(28)
        }
        .onAppear {
            lab.onRecordingChange = { [capture] on in capture.setLabRecording(on) }
            lab.appear()
        }
        .onDisappear { lab.disappear() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("信号实验室")
                .font(.system(size: 26, weight: .bold)).foregroundColor(Theme.primary)
            Text("Phase 0：每个信号先通过带标签的协议验证，再进入统计。录制结果保存为 fixture，作为之后的单元测试。")
                .font(.system(size: 13)).foregroundColor(Theme.secondary)
        }
    }

    // MARK: 按键重复

    private var keyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "按键重复（autorepeat）",
                           help: "CGEventTap keyDown 的 keyboardEventAutorepeat 字段：按住产生的重复事件该字段非 0。",
                           trailing: AnyView(Button("清零") { lab.resetKeyTotals() }.buttonStyle(.borderless)))
                let totals = lab.snapshot?.keyTotals ?? LabKeyCounts()
                HStack(spacing: 28) {
                    metric("\(totals.presses)", "按下")
                    metric("\(totals.repeats)", "重复事件")
                    metric("\(totals.presses + totals.repeats)", "v1 会记为")
                }
                if let last = lab.snapshot?.lastKey {
                    Text("最近：\(last.keyID) · \(last.isRepeat ? "重复" : "按下")")
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundColor(last.isRepeat ? Theme.trackpad : Theme.primary)
                } else {
                    Text("按住任意键试试。").font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
            }
        }
    }

    // MARK: P1 时间戳单位

    private var timestampCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(title: "事件时间戳单位",
                           help: "CGEvent.timestamp 原始增量 ÷ 系统 uptime 增量。≈ 1e9 为纳秒；≈ mach tick 频率（Apple Silicon 为 2400 万）则 v1 的「÷1e9 当秒」是错的。")
                let probe = lab.snapshot?.timestampProbe
                if let rate = probe?.unitsPerSecond {
                    let unit = LabEvaluation.timestampUnit(unitsPerSecond: rate)
                    HStack(spacing: 28) {
                        metric(String(format: "%.4g", rate), "原始单位 / 秒")
                        metric(String(format: "%.4g", LabEvaluation.machTicksPerSecond), "mach tick / 秒")
                        metric("\(probe?.samples ?? 0)", "样本")
                    }
                    Text(timestampVerdict(unit))
                        .font(.system(size: 13))
                        .foregroundColor(unit == .nanoseconds ? Theme.ok : Theme.trackpad)
                } else {
                    Text("按几下键或点击几次，跨度超过 1 秒后给出结论。")
                        .font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
            }
        }
    }

    private func timestampVerdict(_ unit: LabEvaluation.TimestampUnit) -> String {
        switch unit {
        case .nanoseconds: return "纳秒：v1 的换算正确。"
        case .machTicks: return "mach tick：v1 把时间放大了约 \(String(format: "%.0f", 1e9 / LabEvaluation.machTicksPerSecond)) 倍，新捕获层须改用 uptime。"
        case .unknown: return "与两种候选都不吻合：多采几次再看。"
        }
    }

    // MARK: P8 输入源

    private var inputSourceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "输入源",
                           help: "只读输入源元数据（ID、类型、语言），不读文字。依次切换 ABC / 拼音，并试试拼音内 Shift 切英文、Caps Lock 切换，看哪些切换系统能看到。",
                           trailing: AnyView(Button("保存") { lab.saveSeenSources() }
                            .buttonStyle(.borderless).disabled(lab.seenSources.isEmpty)))
                if let current = lab.inputSource {
                    Text(current.id)
                        .font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundColor(Theme.primary)
                    Text("\(current.kind.rawValue) · \(current.isKeyboardLayout ? "键盘布局" : "输入法") · \(current.languages.prefix(3).joined(separator: ", "))")
                        .font(.system(size: 12)).foregroundColor(Theme.secondary)
                }
                HStack(spacing: 28) {
                    metric("\(lab.sourceNotifications)", "切换通知")
                    metric("\(lab.sourceChangesByPoll)", "轮询发现的切换")
                }
                ForEach(lab.seenSources, id: \.self) { s in
                    Text("\(s.kind.rawValue.padding(toLength: 10, withPad: " ", startingAt: 0)) \(s.id)")
                        .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.primary)
                }
                if let url = lab.sourcesSavedURL {
                    Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        .buttonStyle(.link).font(.system(size: 12))
                }
            }
        }
    }

    // MARK: 触点原始字段

    private var contactsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "触点原始字段",
                           help: "zTotal = 电容总量（v1 当作压力使用）；pressure = MTTouch offset 52 按 Float 解读（待验证）；raw = 同 4 字节按 Int32 解读。",
                           trailing: AnyView(
                            Text(lab.snapshot?.frameRateHz.map { String(format: "%.0f Hz", $0) } ?? "— Hz")
                                .font(.system(size: 12, design: .monospaced)).foregroundColor(Theme.secondary)))
                let contacts = lab.snapshot?.contacts ?? []
                Grid(alignment: .trailing, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow {
                        ForEach(["手指", "zTotal", "pressure", "raw", "density", "轴 mm"], id: \.self) { h in
                            Text(h).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.secondary)
                        }
                    }
                    ForEach(contacts) { c in
                        GridRow {
                            Text("\(c.touchID & 0xFFFF)")
                            Text(String(format: "%.3f", c.capacitance))
                            Text(String(format: "%.3f", c.pressure)).foregroundColor(Theme.keyboard)
                            Text(String(format: "%08X", UInt32(bitPattern: c.pressureRawBits)))
                            Text(String(format: "%.3f", c.density))
                            Text(String(format: "%.1f×%.1f", c.majorAxis, c.minorAxis))
                        }
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(Theme.primary)
                    }
                }
                if contacts.isEmpty {
                    Text("把手指放在触控板上。").font(.system(size: 13)).foregroundColor(Theme.secondary)
                }
            }
        }
    }

    // MARK: 实时曲线

    private var traceCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 10) {
                CardHeader(title: "最近 5 秒",
                           help: "两条曲线各自按本窗口最大值归一化；竖线 = 左键按下（开启轻点时，轻点也会产生按下）。看点击与重按时哪条曲线跳得更明显。")
                HStack(spacing: 16) {
                    legend(Theme.keyboard, "pressure", peak: lab.snapshot?.recentFrames.map(\.maxPressure).max())
                    legend(Theme.trackpad, "zTotal", peak: lab.snapshot?.recentFrames.map(\.maxCapacitance).max())
                    legend(Theme.secondary, "点击", peak: nil)
                }
                TraceCanvas(snapshot: lab.snapshot)
                    .frame(height: 140)
            }
        }
    }

    private func legend(_ color: Color, _ label: String, peak: Double?) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 14, height: 4)
            Text(peak.map { "\(label) 峰值 \(String(format: "%.3f", $0))" } ?? label)
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
        }
    }

    // MARK: 协议

    private var protocolsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 16) {
                CardHeader(title: "验证协议")
                if let proto = lab.running {
                    runningView(proto)
                } else {
                    ForEach(LabProtocol.all) { proto in
                        protocolRow(proto)
                    }
                }
            }
        }
    }

    private func protocolRow(_ proto: LabProtocol) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(proto.title).font(.system(size: 14, weight: .semibold)).foregroundColor(Theme.primary)
                    Text(proto.summary).font(.system(size: 12)).foregroundColor(Theme.secondary)
                }
                Spacer()
                Button("开始") { lab.start(proto) }
                    .disabled(capture.status != .recording)
            }
            if let result = lab.results[proto.id] {
                resultView(result)
            }
            Divider().overlay(Theme.hairline)
        }
    }

    private func runningView(_ proto: LabProtocol) -> some View {
        let step = proto.steps[lab.stepIndex]
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(proto.title) · 第 \(lab.stepIndex + 1)/\(proto.steps.count) 步")
                .font(.system(size: 12)).foregroundColor(Theme.secondary)
            Text(step.instruction)
                .font(.system(size: 20, weight: .semibold)).foregroundColor(Theme.primary)
            HStack(spacing: 12) {
                Text("\(lab.stepRemaining) 秒")
                    .font(.system(size: 28, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundColor(Theme.keyboard)
                Spacer()
                Button("取消") { lab.cancel() }
                // 不绑 Return 快捷键：Lab 页吞掉非 ⌘ 按键（防 NSBeep），快捷键收不到。
                Button(lab.stepIndex + 1 < proto.steps.count ? "下一步" : "完成") { lab.advance(proto, byUIClick: true) }
            }
        }
    }

    private func resultView(_ result: LabModel.Result) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: result.verdict.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundColor(result.verdict.passed ? Theme.ok : Theme.trackpad)
                Text(result.verdict.passed ? "通过" : "未通过")
                    .font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.primary)
            }
            ForEach(result.verdict.lines, id: \.self) { line in
                Text(line).font(.system(size: 12)).foregroundColor(Theme.primary)
            }
            if let p = result.pressure, let c = result.capacitance {
                Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow {
                        ForEach(["", "静置 P90", "轻点峰值", "加压 max", "点击峰值", "重按峰值", "可分"], id: \.self) {
                            Text($0).font(.system(size: 11, weight: .semibold)).foregroundColor(Theme.secondary)
                        }
                    }
                    levelRow("pressure", p)
                    levelRow("zTotal", c)
                }
            }
            if let url = result.fixtureURL {
                Button("在访达中显示 fixture") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.link).font(.system(size: 12))
            } else if let error = result.saveError {
                Text("fixture 保存失败：\(error)").font(.system(size: 12)).foregroundColor(Theme.trackpad)
            }
        }
        .padding(.leading, 4)
    }

    private func levelRow(_ name: String, _ l: LabEvaluation.SignalLevels) -> some View {
        GridRow {
            Text(name).font(.system(size: 12, weight: .semibold))
            ForEach(Array([l.rest, l.tap, l.push, l.click, l.force].enumerated()), id: \.offset) {
                Text(String(format: "%.3f", $0.element))
            }
            Text(l.isSeparable() ? "是" : "否").foregroundColor(l.isSeparable() ? Theme.ok : Theme.trackpad)
        }
        .font(.system(size: 12, design: .monospaced))
        .foregroundColor(Theme.primary)
    }

    private func metric(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 24, weight: .bold).monospacedDigit()).foregroundColor(Theme.primary)
            Text(label).font(.system(size: 12)).foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - 实时曲线画布

private struct TraceCanvas: View {
    let snapshot: LabSnapshot?

    var body: some View {
        Canvas { ctx, size in
            ctx.stroke(Path(CGRect(origin: .zero, size: size)), with: .color(Theme.hairline), lineWidth: 1)
            guard let s = snapshot else { return }
            let window = SignalLabWindow.seconds
            func x(_ t: TimeInterval) -> CGFloat { size.width * CGFloat(1 - (s.now - t) / window) }
            for click in s.recentClicks where click.button == 0 {
                var p = Path()
                p.move(to: CGPoint(x: x(click.t), y: 0))
                p.addLine(to: CGPoint(x: x(click.t), y: size.height))
                ctx.stroke(p, with: .color(Theme.secondary.opacity(0.6)), lineWidth: 1)
            }
            func trace(_ value: (LabFrame) -> Double, _ color: Color) {
                let peak = s.recentFrames.map(value).max() ?? 0
                guard peak > 0 else { return }
                var path = Path()
                var last: TimeInterval?
                for f in s.recentFrames {
                    let pt = CGPoint(x: x(f.t), y: size.height * CGFloat(1 - value(f) / peak) * 0.92 + 4)
                    // 无接触的间隔（> 50ms 无帧）断开曲线
                    if let l = last, f.t - l < 0.05 { path.addLine(to: pt) } else { path.move(to: pt) }
                    last = f.t
                }
                ctx.stroke(path, with: .color(color), lineWidth: 1.5)
            }
            trace({ $0.maxCapacitance }, Theme.trackpad)
            trace({ $0.maxPressure }, Theme.keyboard)
        }
    }
}

private enum SignalLabWindow {
    static let seconds: TimeInterval = 5
}

// MARK: - 卡片标题（Lab 专用）

struct CardHeader: View {
    let title: String
    var help: String? = nil
    var trailing: AnyView? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.headline)
            if let help {
                Image(systemName: "questionmark.circle").foregroundStyle(Theme.tertiary).help(help)
            }
            Spacer()
            if let trailing { trailing }
        }
    }
}
