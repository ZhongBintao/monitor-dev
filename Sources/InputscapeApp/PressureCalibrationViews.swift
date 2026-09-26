import SwiftUI
import InputscapeKit

// MARK: - 按压测试与校准（整合模块）

/// 实时测试 + 校准一体：
/// 1. 实时测试（常驻）：按压触控板，实时显示系统压力档判定（轻按/重按）
///    与接触压力读数——校准假设「轻按无触觉反馈、按到触觉咔哒（震动）
///    即为重按」可在此现场验证（系统 stage 2 即触觉门限）；
/// 2. 校准（引导式两阶段）：轻按采集 → 重按采集，按实时系统判定自动
///    标注样本，学出用户设备的轻/重接触压力分界。
///
/// 只读内存态 + UserDefaults 校准结果，不接触任何落盘统计数据。
struct PressureTestCalibrationView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var live: LiveModel
    @Environment(\.dismiss) private var dismiss

    /// sheet 内的流程状态：实时测试 → 轻按采集 → 重按采集 → 结果。
    private enum Flow: Equatable {
        case testing
        case collectingLight
        case collectingHeavy
        case result(PressureCalibrationSession.Result)
    }

    @State private var flow: Flow = .testing
    /// 当前阶段开始时刻（采集计时用）。
    @State private var phaseStartedAt = Date()
    /// 校准采样定时器（存储型：onAppear 启动 / onDisappear 停止）。
    @State private var samplingTimer: Timer?
    /// 每阶段采集时长（秒）。
    private let phaseDuration: TimeInterval = 6

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    hypothesisNote
                    liveTestCard
                    calibrationCard
                }
                .padding(20)
            }
        }
        .frame(width: 520, height: 560)
        .background(Theme.background)
        .onDisappear { model.cancelCalibration() }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("按压测试与校准")
                    .font(.system(size: 20, weight: .bold)).foregroundColor(Theme.navy)
                Text("实时验证系统判定，按需校准你的设备特征。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
            }
            Spacer()
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 20))
                    .foregroundColor(Theme.tertiary)
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
        .padding(20)
    }

    /// 校准假设说明（用户要求显式呈现，便于现场验证）。
    private var hypothesisNote: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text("判定依据").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                Text("校准假设：轻按触控板不会产生震动；触发触觉震动反馈（咔哒感）的按压才算重按。系统的重按门限正是这个触觉阈值——请实际按压并观察下方判定是否与你的触觉感受一致。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 实时测试卡：当前判定徽章 + 诊断读数（stage / 接触压力）。
    private var liveTestCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("实时测试").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                    Spacer()
                    Text("现在就按：观察判定与触觉是否一致")
                        .font(.system(size: 11)).foregroundColor(Theme.tertiary)
                }
                HStack(spacing: 16) {
                    // 实时判定徽章（周期刷新超时态）：优先系统压力档信号；
                    // 本机不投递 type 34 时按接触压力对照当前分界实时判定
                    //（校准激活用学到的分界，否则默认 1.0）——两种按法
                    // 的差异从此在无 stage 机型上可见。
                    TimelineView(.periodic(from: .now, by: 0.3)) { context in
                        let stage = live.effectivePressureStage(now: context.date)
                        let maxPressure = live.touchDots.map(\.pressure).max()
                        Text(badgeText(stage, maxPressure: maxPressure))
                            .font(.system(size: 22, weight: .bold))
                            .foregroundColor(badgeColor(stage, maxPressure: maxPressure))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(badgeColor(stage, maxPressure: maxPressure).opacity(0.12)))
                    }
                }
                HStack {
                    Text(diagnosticText)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(Theme.tertiary)
                        .monospacedDigit()
                    Spacer()
                }
            }
        }
    }

    /// 校准卡：引导两阶段采集（按实时系统判定自动标注样本）。
    private var calibrationCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("校准").font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
                    Spacer()
                    if flow != .testing {
                        Button("取消校准") { cancel() }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
                switch flow {
                case .testing:
                    VStack(alignment: .leading, spacing: 8) {
                        Text("校准会引导你分别做几次轻按与重按（各 6 秒），按实时判定自动归类，学出你设备的轻/重分界。校准成功后可在设置中开启「校准判定」。")
                            .font(.system(size: 12)).foregroundColor(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("开始校准") { beginLightPhase() }
                            .buttonStyle(.borderedProminent)
                            .tint(Theme.keyPurple)
                    }
                case .collectingLight:
                    collectingBody(instruction: "用不触发咔哒的力度，反复轻按触控板",
                                   detail: "直到本阶段结束；样本按实时判定自动归入「轻按」",
                                   phaseTitle: "第 1 步 · 轻按采集")
                case .collectingHeavy:
                    collectingBody(instruction: "按到底、触发触觉咔哒（震动），反复重按",
                                   detail: "直到本阶段结束；样本按实时判定自动归入「重按」",
                                   phaseTitle: "第 2 步 · 重按采集")
                case .result(let result):
                    resultBody(result)
                }
            }
        }
    }

    private func collectingBody(instruction: String, detail: String, phaseTitle: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(phaseTitle).font(.system(size: 13, weight: .semibold)).foregroundColor(Theme.navy)
                Spacer()
                Text(progressText)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.secondary)
                    .monospacedDigit()
            }
            // 阶段进度条（TimelineView 驱动，无需额外 Timer）。
            TimelineView(.periodic(from: .now, by: 0.1)) { context in
                let fraction = min(1, context.date.timeIntervalSince(phaseStartedAt) / phaseDuration)
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.coralSoft)
                        Capsule().fill(Theme.coral).frame(width: geo.size.width * fraction)
                    }
                }
                .frame(height: 8)
            }
            Text(instruction).font(.system(size: 13, weight: .medium)).foregroundColor(Theme.navy)
            Text(detail).font(.system(size: 11)).foregroundColor(Theme.tertiary)
            sampleCounts
        }
        .onAppear {
            phaseStartedAt = Date()
            startSampling()
        }
        .onDisappear { stopSampling() }
    }

    private var sampleCounts: some View {
        Text("已采集：轻按 \(model.activeCalibrationSession?.lightSampleCount ?? 0) 帧 · 重按 \(model.activeCalibrationSession?.heavySampleCount ?? 0) 帧")
            .font(.system(size: 11)).foregroundColor(Theme.tertiary)
            .monospacedDigit()
    }

    private func resultBody(_ result: PressureCalibrationSession.Result) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if result.isSuccess {
                Label("校准完成", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.statusGreen)
                Text("轻/重分界 \(String(format: "%.2f", result.threshold))（轻按中位 \(String(format: "%.2f", result.lightMedian)) · 重按 P90 \(String(format: "%.2f", result.heavyP90))，差异明显）。已自动开启「校准判定」，可在设置中关闭。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Label("差异不明显", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 14, weight: .bold)).foregroundColor(Theme.coral)
                Text("本次采集未能区分轻按与重按（类间差异 \(String(format: "%.2f", result.separation))，需要 ≥ \(String(format: "%.1f", PressureCalibrationSession.Result.minimumSeparation))），已保留默认分界。可重试：重按时确保按到触觉咔哒，每次按住片刻再松开。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("样本：轻按 \(result.lightSamples) 帧 · 重按 \(result.heavySamples) 帧")
                .font(.system(size: 11)).foregroundColor(Theme.tertiary)
                .monospacedDigit()
            HStack {
                Button("重新校准") { beginLightPhase() }
                    .buttonStyle(.bordered)
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.keyPurple)
                Spacer()
            }
        }
    }

    // MARK: 动作与展示辅助

    // MARK: 采样定时器

    /// 采样：定时读取接触压力交给会话（20Hz，触点发布 30Hz）；
    /// 无需依赖系统压力档信号——无信号时由会话按采集阶段标注。
    /// 信号形态决定采样源：轻按是稳态接触 → 直读最新帧即可；
    /// 重按是瞬态峰值（帧源 125Hz，短峰 < 50ms 会被点采漏掉）
    /// → 峰值保持，取近 0.1s 接触压力环最大值，不漏峰。
    ///
    /// 必须用存储型 Timer（onAppear 启动 / onDisappear 停止），不能用
    /// body 内联 onReceive(Timer.publish)：sheet 打开期间 touchDots 被
    /// 30Hz 发布脉冲重新赋值（空数组也触发 objectWillChange），本视图
    /// 每秒重渲染 ~30 次，内联 publisher 每次重算都被替换重订阅，
    /// 0.05s 定时器活不到第一次触发（最小复现实测 ticks=0，校准恒 0 帧）。
    private func startSampling() {
        stopSampling()
        let model = self.model
        let live = self.live
        let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
            Task { @MainActor in
                let pressures: [Double]
                if flow == .collectingLight {
                    pressures = live.touchDots.map(\.pressure)
                } else if let peak = TouchpointMonitor.recentMaxContactPressure(within: 0.1) {
                    pressures = [peak]
                } else {
                    pressures = []
                }
                model.calibrationDidReceiveTouchPressures(pressures)
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        samplingTimer = timer
    }

    private func stopSampling() {
        samplingTimer?.invalidate()
        samplingTimer = nil
    }

    private func beginLightPhase() {
        model.startCalibration()
        flow = .collectingLight
        phaseStartedAt = Date()
        schedulePhaseEnd()
    }

    private func schedulePhaseEnd() {
        // 阶段计时结束自动推进（轻按 6s → 重按 6s → 计算）。
        DispatchQueue.main.asyncAfter(deadline: .now() + phaseDuration) {
            switch flow {
            case .collectingLight:
                model.advanceCalibrationToHeavy()
                flow = .collectingHeavy
                phaseStartedAt = Date()
                schedulePhaseEnd()
            case .collectingHeavy:
                if let result = model.finishCalibration() {
                    flow = .result(result)
                } else {
                    flow = .testing
                }
            default:
                break
            }
        }
    }

    private func cancel() {
        model.cancelCalibration()
        flow = .testing
    }

    private var progressText: String {
        let remaining = max(0, phaseDuration - Date().timeIntervalSince(phaseStartedAt))
        return String(format: "%.0f 秒", remaining.rounded())
    }

    private var diagnosticText: String {
        // 系统压力档信号三态：从未收到 / 收到但超时中断 / 存活。
        let signalText: String
        if live.pressureStageAt == nil {
            signalText = "压力档信号 未收到（本机不投递：判定与徽章按接触压力对照分界）"
        } else if live.effectivePressureStage() != nil {
            signalText = "压力档信号 已收到"
        } else {
            signalText = "压力档信号 中断"
        }
        let pressures = live.touchDots.map(\.pressure)
        let contactText = pressures.isEmpty
            ? "接触压力 —"
            : String(format: "接触压力 %.2f", (pressures.max() ?? 0))
        return "\(signalText) · \(contactText)"
    }

    private func badgeText(_ stage: Int?, maxPressure: Double?) -> String {
        switch stage {
        case 2: return "重按"
        case 1: return "轻按"
        default:
            guard let pressure = maxPressure, pressure > 0 else { return "未接触" }
            return pressure >= model.effectivePressureThreshold ? "重按" : "轻按"
        }
    }

    private func badgeColor(_ stage: Int?, maxPressure: Double?) -> Color {
        switch stage {
        case 2: return Theme.coral
        case 1: return Theme.keyPurple
        default:
            guard let pressure = maxPressure, pressure > 0 else { return Theme.tertiary }
            return pressure >= model.effectivePressureThreshold ? Theme.coral : Theme.keyPurple
        }
    }
}
