import SwiftUI
import Charts
import InputscapeKit

// MARK: - 触控板操作

struct TrackpadOpsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selectedHeatmapCell: TouchHeatmapPanel.Cell?
    @State private var selectedContinuousCell: TouchHeatmapContinuousPanel.Cell?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    compositionCard
                    hourlyCard
                }
                HStack(alignment: .top, spacing: 16) {
                    if model.deviceProfile.supportsForceTouch {
                        pressureCard
                    }
                    rankingCard
                }
                heatmapCard
            }
            .padding(20)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("触控板操作构成")
                        .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
                    Text("点击、滚动、智能缩放、滑动与 Force Touch 的聚合构成，以及触点热力分布。")
                        .font(.system(size: 14)).foregroundColor(Theme.secondary)
                }
                Spacer()
                RefreshButton()
            }
            StateBanner(status: model.status,
                        permission: model.permission,
                        deviceConfirmed: model.deviceProfile.confirmed,
                        supportsForceTouch: model.deviceProfile.supportsForceTouch)
        }
    }

    private var snapshot: AggregateSnapshot { model.snapshot }

    private var compositionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 14) {
                Text("操作构成").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if snapshot.trackpadOps == 0 {
                    EmptyStateView(title: "还没有触控操作记录",
                                   detail: "开始观察后，这里会展示点击、滚动、智能缩放、滑动等操作的构成。")
                    .frame(height: 160)
                } else {
                    // 类别较多，只展示有数据的类别；占比按有数据部分归一。
                    ForEach(snapshot.trackpadRanking, id: \.kind) { entry in
                        row(kind: entry.kind, count: entry.count, fraction: entry.fraction)
                    }
                }
            }
        }
    }

    private func row(kind: TrackpadOperationKind, count: Int, fraction: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(kind.isScroll ? Theme.coral.opacity(0.65) : Theme.coral)
                    .frame(width: 8, height: 8)
                Text(kind.label).font(.system(size: 13)).foregroundColor(Theme.navy)
                Spacer()
                Text("\(formatCount(count)) 次 · \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.coralSoft)
                    if count > 0 {
                        Capsule().fill(Theme.coral)
                            .frame(width: max(8, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(kind.label) \(count) 次，占比 \(Int((fraction * 100).rounded()))%")
    }

    private var hourlyCard: some View {
        let points = hourlyPoints
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                Text("发生时段").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                Text("各操作在一天 24 小时中的分布（\(model.rangeLabel)）。")
                    .font(.system(size: 12)).foregroundColor(Theme.secondary)
                if points.allSatisfy({ $0.count == 0 }) {
                    EmptyStateView(title: "暂无时段数据", detail: "观察进行中时会按小时累计各类操作。")
                        .frame(height: 160)
                } else {
                    Chart {
                        ForEach(points) { p in
                            BarMark(x: .value("小时", p.hourLabel),
                                    y: .value("次数", p.count))
                                .foregroundStyle(Theme.coral.opacity(0.85))
                        }
                    }
                    .chartXAxis {
                        AxisMarks(values: ["00", "06", "12", "18", "23"]) { value in
                            AxisValueLabel() {
                                if let hour = value.as(String.self) {
                                    Text("\(hour)时").font(.system(size: 10))
                                }
                            }
                            .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
    }

    private struct HourPoint: Identifiable {
        let hour: Int
        let count: Int
        var hourLabel: String { String(format: "%02d", hour) }
        var id: Int { hour }
    }

    private var hourlyPoints: [HourPoint] {
        var merged = Array(repeating: 0, count: 24)
        for (_, series) in snapshot.hourlyByOp {
            for (i, v) in series.enumerated() where i < 24 { merged[i] += v }
        }
        return (0..<24).map { HourPoint(hour: $0, count: merged[$0]) }
    }

    private var rankingCard: some View {
        let ranking = snapshot.trackpadRanking
        return Card {
            VStack(alignment: .leading, spacing: 10) {
                Text("Top 操作排行").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if ranking.isEmpty {
                    Text("暂无数据。").font(.system(size: 13)).foregroundColor(Theme.secondary)
                } else {
                    ForEach(Array(ranking.enumerated()), id: \.offset) { index, entry in
                        HStack {
                            Text("\(index + 1)")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundColor(Theme.tertiary)
                                .frame(width: 18)
                            Text(entry.kind.label)
                                .font(.system(size: 13, weight: .medium))
                                .foregroundColor(Theme.navy)
                            Spacer()
                            Text("\(formatCount(entry.count)) 次")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundColor(Theme.coral)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
    }

    /// 按压强度分布卡：MTTouch 手指连续压力（0–1，接触中按帧聚合）的
    /// 20 桶直方图 + 轻/中/深三档汇总 + 平均压力。
    /// 数据源为触控板硬件连续压力，真随按压力度变化（旧方案
    /// kCGMouseEventPressure 为点击瞬间标量，无区分度，已废弃）。
    /// 设备不支持 Force Touch 时整卡隐藏（非 FT 触控板压力值域未知）。
    private var pressureCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("按压强度分布").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "基于触控板硬件的手指连续压力（0–1，接触中按帧聚合）：按压越重、越久，右侧桶计数越高。轻/中/深分界 0.25 / 0.55，随探针数据持续校准。只保存直方图计数，不保存原始压力序列。")
                    Spacer()
                    Text("平均按压 \(averagePressureText)")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                        .monospacedDigit()
                }
                if snapshot.touchPressureSamples == 0 {
                    EmptyStateView(title: "暂无按压数据",
                                   detail: "观察进行中时会按手指接触的每一帧累计压力分布。")
                        .frame(height: 120)
                } else {
                    let tiers = snapshot.touchPressureTiers
                    let total = snapshot.touchPressureSamples
                    tierRow(tier: .light, count: tiers.light, total: total)
                    tierRow(tier: .medium, count: tiers.medium, total: total)
                    tierRow(tier: .deep, count: tiers.deep, total: total)
                    pressureHistogram
                }
            }
        }
    }

    private func tierRow(tier: PressureTier, count: Int, total: Int) -> some View {
        let fraction = total > 0 ? Double(count) / Double(total) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Circle().fill(pressureColor(tier)).frame(width: 8, height: 8)
                Text(tier.label).font(.system(size: 13)).foregroundColor(Theme.navy)
                Spacer()
                Text("\(formatCount(count)) 帧 · \(Int((fraction * 100).rounded()))%")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Theme.secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.coralSoft)
                    if count > 0 {
                        Capsule().fill(pressureColor(tier))
                            .frame(width: max(8, geo.size.width * fraction))
                    }
                }
            }
            .frame(height: 7)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(tier.label) \(count) 帧，占比 \(Int((fraction * 100).rounded()))%")
    }

    /// 20 桶压力直方图（0–1，0.05 步进）。
    private var pressureHistogram: some View {
        let points = snapshot.touchPressureHistogram.enumerated().map { index, count in
            HistogramPoint(center: PressureTier.bucketCenter(index), count: count)
        }
        return Chart(points) { point in
            BarMark(x: .value("压力", point.center),
                    y: .value("帧数", point.count),
                    width: .fixed(6))
                .foregroundStyle(Theme.coral.opacity(0.85))
        }
        .chartXAxis {
            AxisMarks(values: [0, 0.25, 0.5, 0.75, 1.0]) { value in
                AxisValueLabel() {
                    if let value = value.as(Double.self) {
                        Text(String(format: "%.2f", value))
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(Theme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading) {
                AxisGridLine().foregroundStyle(Theme.hairline)
                AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            }
        }
        .frame(height: 110)
    }

    private struct HistogramPoint: Identifiable {
        let center: Double
        let count: Int
        var id: Double { center }
    }

    private var averagePressureText: String {
        guard let average = snapshot.touchPressureAverage else { return "—" }
        return String(format: "%.2f", average)
    }

    /// 三档同色系深浅区分；同时以数字与文字呈现（不只依赖颜色）。
    private func pressureColor(_ tier: PressureTier) -> Color {
        switch tier {
        case .light: return Theme.coral.opacity(0.45)
        case .medium: return Theme.coral.opacity(0.7)
        case .deep: return Theme.coral
        }
    }

    // MARK: - 触点热力图

    /// 触点热力图卡：触点位置按 96×64 网格按日聚合，两种显示模式
    /// （设置页切换）渲染同一份数据——「网格 24×16」为 4×4 降采样方块，
    /// 「连续 96×64」为高分辨率 + 高斯扩散的无级热力面。
    /// 颜色只做方向引导：点按格子查看具体次数，附最热区域文字说明。
    private var heatmapCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Text("触点热力图").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    HelpMarker(text: "读取系统触控板多点触控数据，把触点位置按 96×64 网格按日聚合计数。只保存网格计数，不保存轨迹、原始触点流或屏幕坐标；设备不支持时无数据。可在设置中切换「网格 24×16」与「连续 96×64」显示模式。颜色越深表示触碰越频繁，点按格子可查看具体次数。")
                    Spacer()
                    Text(model.heatmapDisplayMode.label)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Theme.tertiary)
                    Text("触碰 \(formatCount(snapshot.touchTotal)) 次")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Theme.secondary)
                }
                if snapshot.touchTotal == 0 {
                    EmptyStateView(title: "暂无触点数据",
                                   detail: "在触控板上操作后会自动累计触点位置分布；设备不支持时无数据。")
                        .frame(height: 140)
                } else {
                    switch model.heatmapDisplayMode {
                    case .grid:
                        TouchHeatmapPanel(grid: DailyRecord.downsampleTouchGridToLegacy(snapshot.touchGrid),
                                          selectedCell: $selectedHeatmapCell)
                            .frame(maxWidth: 460)
                            .frame(maxWidth: .infinity)
                        heatmapFootnote(legend: "网格 24×16",
                                        cell: selectedHeatmapCell.map { TouchHeatmapContinuousPanel.Cell(row: $0.row, column: $0.column) },
                                        columns: DailyRecord.legacyTouchGridColumns,
                                        rows: DailyRecord.legacyTouchGridRows)
                    case .continuous:
                        TouchHeatmapContinuousPanel(grid: snapshot.touchGrid,
                                                    selectedCell: $selectedContinuousCell)
                            .frame(maxWidth: 460)
                            .frame(maxWidth: .infinity)
                        heatmapFootnote(legend: "连续 96×64",
                                        cell: selectedContinuousCell,
                                        columns: DailyRecord.touchGridColumns,
                                        rows: DailyRecord.touchGridRows)
                    }
                }
            }
        }
        .onChange(of: model.heatmapDisplayMode) { _ in
            selectedHeatmapCell = nil
            selectedContinuousCell = nil
        }
    }

    /// 读数说明（不只依赖颜色）：优先显示选中格，否则显示最热区域。
    @ViewBuilder
    private func heatmapFootnote(legend: String,
                                 cell: TouchHeatmapContinuousPanel.Cell?,
                                 columns: Int, rows: Int) -> some View {
        if let cell {
            let count = snapshot.touchCount(row: cell.row, column: cell.column)
            Text("\(legend) · 选中格：第 \(cell.row + 1) 行 · 第 \(cell.column + 1) 列，\(formatCount(count)) 次触碰。")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Theme.navy)
        } else if let peak = snapshot.touchPeak {
            Text("\(legend) · 最热区域在第 \(peak.row + 1) 行 · 第 \(peak.column + 1) 列（网格 \(columns)×\(rows)），共 \(formatCount(peak.count)) 次触碰；点按格子查看具体次数。")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
        } else {
            Text("\(legend) · 网格 \(columns)×\(rows)，点按格子查看具体次数。")
                .font(.system(size: 12))
                .foregroundColor(Theme.secondary)
        }
    }
}

// MARK: - 触点热力图面板（网格 24×16 显示模式）

/// 圆角触控板面板 + 24×16 珊瑚红色阶网格（Canvas 绘制，单次布局无逐格视图）。
/// 数据为 96×64 网格 4×4 降采样结果。
struct TouchHeatmapPanel: View {
    struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    let grid: [Int]
    @Binding var selectedCell: Cell?

    /// 面板纵横比（实物触控板 ~16:10）。
    private static let panelAspectRatio: CGFloat = 1.6

    var body: some View {
        Canvas { context, size in
            let bounds = CGRect(origin: .zero, size: size)
            let panel = RoundedRectangle(cornerRadius: size.height * 0.085, style: .continuous)
                .path(in: bounds)
            context.fill(panel, with: .color(Theme.background))
            context.stroke(panel, with: .color(Theme.hairline), lineWidth: 1)

            let metrics = gridMetrics(size: size)
            let maxCount = grid.max() ?? 0
            for row in 0..<DailyRecord.legacyTouchGridRows {
                for column in 0..<DailyRecord.legacyTouchGridColumns {
                    let index = row * DailyRecord.touchGridColumns + column
                    let count = index < grid.count ? grid[index] : 0
                    let rect = cellRect(metrics: metrics, row: row, column: column)
                    let cellPath = Path(roundedRect: rect, cornerRadius: metrics.cellSize * 0.28)
                    if count > 0, maxCount > 0 {
                        let intensity = 0.18 + 0.82 * Double(count) / Double(maxCount)
                        context.fill(cellPath, with: .color(Theme.coral.opacity(intensity)))
                    } else {
                        context.fill(cellPath, with: .color(Theme.coral.opacity(0.07)))
                    }
                    if selectedCell == Cell(row: row, column: column) {
                        context.stroke(cellPath, with: .color(Theme.navy), lineWidth: 1.6)
                    }
                }
            }
        }
        .aspectRatio(Self.panelAspectRatio, contentMode: .fit)
        .contentShape(Rectangle())
        .overlay(GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(at: location, size: proxy.size)
                }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: 布局度量

    private struct GridMetrics {
        let originX: CGFloat
        let originY: CGFloat
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        var cellSize: CGFloat { min(cellWidth, cellHeight) }
    }

    /// 网格区内嵌于面板（留出触控板边框视觉空间），24×16 单元。
    private func gridMetrics(size: CGSize) -> GridMetrics {
        let padX = size.width * 0.055
        let padY = size.height * 0.075
        return GridMetrics(
            originX: padX,
            originY: padY,
            cellWidth: (size.width - padX * 2) / CGFloat(DailyRecord.legacyTouchGridColumns),
            cellHeight: (size.height - padY * 2) / CGFloat(DailyRecord.legacyTouchGridRows)
        )
    }

    private func cellRect(metrics: GridMetrics, row: Int, column: Int) -> CGRect {
        let gap = metrics.cellSize * 0.14
        let x = metrics.originX + CGFloat(column) * metrics.cellWidth
        let y = metrics.originY + CGFloat(row) * metrics.cellHeight
        return CGRect(x: x + gap / 2, y: y + gap / 2,
                      width: metrics.cellWidth - gap,
                      height: metrics.cellHeight - gap)
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let metrics = gridMetrics(size: size)
        let column = Int((location.x - metrics.originX) / metrics.cellWidth)
        let row = Int((location.y - metrics.originY) / metrics.cellHeight)
        guard row >= 0, row < DailyRecord.legacyTouchGridRows,
              column >= 0, column < DailyRecord.legacyTouchGridColumns else {
            selectedCell = nil
            return
        }
        let cell = Cell(row: row, column: column)
        selectedCell = selectedCell == cell ? nil : cell
    }

    private var accessibilitySummary: String {
        let total = grid.reduce(0, +)
        if let peak = touchPeak(grid: grid) {
            return "触点热力图，共 \(total) 次触碰；最热区域第 \(peak.row + 1) 行第 \(peak.column + 1) 列，\(peak.count) 次。"
        }
        return "触点热力图，暂无触碰记录。"
    }

    private func touchPeak(grid: [Int]) -> (count: Int, row: Int, column: Int)? {
        var best: (count: Int, row: Int, column: Int)?
        for row in 0..<DailyRecord.legacyTouchGridRows {
            for column in 0..<DailyRecord.legacyTouchGridColumns {
                let index = row * DailyRecord.legacyTouchGridColumns + column
                let count = index < grid.count ? grid[index] : 0
                if count > 0, count > (best?.count ?? 0) {
                    best = (count, row, column)
                }
            }
        }
        return best
    }
}

// MARK: - 触点热力图面板（连续 96×64 显示模式）

/// 高分辨率热力面：96×64 格点按热度着色后整体高斯扩散，
/// 视觉为一整块无级连续区域；面板边框与选中格描边走独立不模糊层。
struct TouchHeatmapContinuousPanel: View {
    struct Cell: Equatable {
        let row: Int
        let column: Int
    }

    let grid: [Int]
    @Binding var selectedCell: Cell?

    /// 面板纵横比（实物触控板 ~16:10）。
    private static let panelAspectRatio: CGFloat = 1.6

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let cornerRadius = size.height * 0.085
            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(Theme.background)
                Canvas { context, _ in
                    let metrics = gridMetrics(size: size)
                    let maxCount = grid.max() ?? 0
                    guard maxCount > 0 else { return }
                    for row in 0..<DailyRecord.touchGridRows {
                        for column in 0..<DailyRecord.touchGridColumns {
                            let index = row * DailyRecord.touchGridColumns + column
                            let count = index < grid.count ? grid[index] : 0
                            guard count > 0 else { continue }
                            let rect = cellRect(metrics: metrics, row: row, column: column)
                            let intensity = 0.22 + 0.78 * Double(count) / Double(maxCount)
                            let path = Path(roundedRect: rect, cornerRadius: rect.width * 0.3)
                            context.fill(path, with: .color(Theme.coral.opacity(intensity)))
                        }
                    }
                }
                .blur(radius: max(2, size.height * 0.014))
                Canvas { context, _ in
                    let metrics = gridMetrics(size: size)
                    if let selected = selectedCell {
                        let rect = cellRect(metrics: metrics, row: selected.row, column: selected.column)
                        let path = Path(roundedRect: rect, cornerRadius: rect.width * 0.3)
                        context.stroke(path, with: .color(Theme.navy), lineWidth: 1.6)
                    }
                }
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Theme.hairline, lineWidth: 1)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .aspectRatio(Self.panelAspectRatio, contentMode: .fit)
        .contentShape(Rectangle())
        .overlay(GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { location in
                    handleTap(at: location, size: proxy.size)
                }
        })
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    // MARK: 布局度量（96×64）

    private struct GridMetrics {
        let originX: CGFloat
        let originY: CGFloat
        let cellWidth: CGFloat
        let cellHeight: CGFloat
        var cellSize: CGFloat { min(cellWidth, cellHeight) }
    }

    private func gridMetrics(size: CGSize) -> GridMetrics {
        let padX = size.width * 0.05
        let padY = size.height * 0.07
        return GridMetrics(
            originX: padX,
            originY: padY,
            cellWidth: (size.width - padX * 2) / CGFloat(DailyRecord.touchGridColumns),
            cellHeight: (size.height - padY * 2) / CGFloat(DailyRecord.touchGridRows)
        )
    }

    private func cellRect(metrics: GridMetrics, row: Int, column: Int) -> CGRect {
        let x = metrics.originX + CGFloat(column) * metrics.cellWidth
        let y = metrics.originY + CGFloat(row) * metrics.cellHeight
        return CGRect(x: x, y: y, width: metrics.cellWidth, height: metrics.cellHeight)
    }

    private func handleTap(at location: CGPoint, size: CGSize) {
        let metrics = gridMetrics(size: size)
        let column = Int((location.x - metrics.originX) / metrics.cellWidth)
        let row = Int((location.y - metrics.originY) / metrics.cellHeight)
        guard row >= 0, row < DailyRecord.touchGridRows,
              column >= 0, column < DailyRecord.touchGridColumns else {
            selectedCell = nil
            return
        }
        let cell = Cell(row: row, column: column)
        selectedCell = selectedCell == cell ? nil : cell
    }

    private var accessibilitySummary: String {
        let total = grid.reduce(0, +)
        if let peak = snapshotTouchPeak() {
            return "触点热力图，共 \(total) 次触碰；最热区域第 \(peak.row + 1) 行第 \(peak.column + 1) 列，\(peak.count) 次。"
        }
        return "触点热力图，暂无触碰记录。"
    }

    private func snapshotTouchPeak() -> (count: Int, row: Int, column: Int)? {
        var best: (count: Int, row: Int, column: Int)?
        for row in 0..<DailyRecord.touchGridRows {
            for column in 0..<DailyRecord.touchGridColumns {
                let index = row * DailyRecord.touchGridColumns + column
                let count = index < grid.count ? grid[index] : 0
                if count > 0, count > (best?.count ?? 0) {
                    best = (count, row, column)
                }
            }
        }
        return best
    }
}

// MARK: - 使用趋势

struct TrendsView: View {
    @EnvironmentObject var model: AppModel
    @State private var rangeDays = 7
    @State private var selectedDay: String?
    @State private var localSnapshot: AggregateSnapshot = .empty(.last7Days)

    private func reload() {
        localSnapshot = model.snapshotForTrends(dayCount: rangeDays)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                HStack(alignment: .top, spacing: 16) {
                    chartCard
                    detailCard.frame(width: 280)
                }
            }
            .padding(20)
        }
        .onAppear {
            reload()
            if selectedDay == nil { selectedDay = localSnapshot.daySeries.last?.date }
        }
        .onChange(of: rangeDays) { _ in
            reload()
            selectedDay = nil
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("逐日使用趋势")
                    .font(.system(size: 28, weight: .bold)).foregroundColor(Theme.navy)
                Text("按日展示键盘与触控操作量，选中日期查看详情。")
                    .font(.system(size: 14)).foregroundColor(Theme.secondary)
            }
            Spacer()
            HStack(spacing: 2) {
                ForEach([7, 30], id: \.self) { days in
                    Button {
                        rangeDays = days
                        if days == 30 { selectedDay = nil } else { selectedDay = nil }
                    } label: {
                        Text("\(days) 天")
                            .font(.system(size: 13, weight: rangeDays == days ? .semibold : .regular))
                            .foregroundColor(rangeDays == days ? Theme.keyPurple : Theme.secondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(rangeDays == days ? Theme.keyPurpleSoft : Color.clear))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(3)
            .background(Capsule().fill(Theme.background))
            .overlay(Capsule().stroke(Theme.hairline, lineWidth: 1))
        }
    }

    private var series: [DaySeriesPoint] {
        Array(localSnapshot.daySeries.suffix(rangeDays))
    }

    private var chartCard: some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("每日输入量").font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                    Spacer()
                    legend
                }
                if series.isEmpty {
                    EmptyStateView(title: "还没有逐日数据",
                                   detail: "使用几天后，这里会出现按日对比的键盘与触控柱状图。")
                        .frame(height: 220)
                } else {
                    Chart(series) { point in
                        BarMark(x: .value("日期", shortDate(point.date)),
                                y: .value("键盘", point.keyboard))
                            .foregroundStyle(Theme.keyPurple)
                            .opacity(selectedDay == nil || selectedDay == point.date ? 1 : 0.45)
                        BarMark(x: .value("日期", shortDate(point.date)),
                                y: .value("触控", point.trackpad))
                            .foregroundStyle(Theme.coral)
                            .opacity(selectedDay == nil || selectedDay == point.date ? 1 : 0.45)
                    }
                    .chartXAxis {
                        AxisMarks { value in
                            AxisValueLabel {
                                if let label = value.as(String.self) {
                                    Text(label).font(.system(size: 9))
                                }
                            }
                            .foregroundStyle(Theme.tertiary)
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading) {
                            AxisGridLine().foregroundStyle(Theme.hairline)
                            AxisValueLabel().font(.system(size: 10)).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(height: 220)
                    dayChips
                }
            }
        }
    }

    private var legend: some View {
        HStack(spacing: 12) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.keyPurple).frame(width: 9, height: 9)
                Text("键盘").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(Theme.coral).frame(width: 9, height: 9)
                Text("触控").font(.system(size: 11)).foregroundColor(Theme.secondary)
            }
        }
    }

    private var dayChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(series.reversed()) { point in
                    Button {
                        selectedDay = selectedDay == point.date ? nil : point.date
                    } label: {
                        Text(shortDate(point.date))
                            .font(.system(size: 11, weight: selectedDay == point.date ? .semibold : .regular))
                            .foregroundColor(selectedDay == point.date ? .white : Theme.secondary)
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(selectedDay == point.date ? Theme.keyPurple : Theme.background))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var detailCard: some View {
        let point = series.first { $0.date == selectedDay }
        return Card {
            VStack(alignment: .leading, spacing: 14) {
                Text(point?.date ?? "未选择日期")
                    .font(.system(size: 16, weight: .bold)).foregroundColor(Theme.navy)
                if let point {
                    detailRow(icon: "keyboard", color: Theme.keyPurple, title: "按键",
                              value: "\(formatCount(point.keyboard)) 次")
                    detailRow(icon: "cursorarrow.click", color: Theme.coral, title: "触控操作",
                              value: "\(formatCount(point.trackpad)) 次")
                    detailRow(icon: "clock", color: Theme.navy, title: "活跃输入",
                              value: formatDuration(point.activeSeconds))
                } else {
                    EmptyStateView(title: "选择一个日期",
                                   detail: "点击图表下方的日期标签查看当日详情。")
                }
            }
        }
    }

    private func detailRow(icon: String, color: Color, title: String, value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundColor(color).frame(width: 22)
            Text(title).font(.system(size: 13)).foregroundColor(Theme.secondary)
            Spacer()
            Text(value).font(.system(size: 14, weight: .bold)).foregroundColor(Theme.navy)
        }
    }

    private func shortDate(_ day: String) -> String {
        let parts = day.split(separator: "-")
        guard parts.count == 3 else { return day }
        return "\(parts[1])-\(parts[2])"
    }
}
