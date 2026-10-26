import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InputscapeCore
import InputscapeStore
import InputscapeCapture

struct SettingsView: View {
    @Environment(AppState.self) private var state
    @Environment(CaptureSupervisor.self) private var capture
    @Environment(\.database) private var database

    @State private var confirmDeleteToday = false
    @State private var confirmDeleteAll = false
    @State private var message: String?

    var body: some View {
        @Bindable var state = state
        Form {
            Section("记录") {
                LabeledContent("状态") {
                    HStack {
                        Text(capture.status.label)
                        if capture.status == .recording || capture.status == .paused {
                            Button(capture.status == .recording ? "暂停" : "继续") {
                                capture.setPaused(capture.status == .recording)
                            }
                        }
                    }
                }
                LabeledContent("输入监控", value: capture.permission.inputMonitoring ? "已允许" : "未允许")
                LabeledContent("辅助功能", value: capture.permission.accessibility ? "已允许" : "未允许")
                if !capture.permission.granted {
                    HStack {
                        Button("请求授权") { capture.requestPermission() }
                        Button("打开系统设置") {
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
                        }
                    }
                }
                LabeledContent("触控板", value: capture.trackpadAvailable ? "内置触控板" : "不可用")
                LabeledContent("当前输入源", value: capture.inputSource.id.isEmpty ? "—" : capture.inputSource.id)
                if let error = capture.lastWriteError {
                    Text("写入失败：\(error)").foregroundStyle(.red)
                }
            }

            Section {
                Text("只保存按分钟汇总的计数：哪个物理键按了几次、点击与滚动量、触控板落点所在网格、当时的输入法类别。不保存输入的文字、按键顺序、窗口或网页信息、指针坐标。")
                    .font(.callout).foregroundStyle(Theme.secondary)
            } header: {
                Text("隐私")
            }

            Section("数据") {
                if let url = try? InputscapeDatabase.defaultURL() {
                    LabeledContent("数据库") {
                        Button(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                            NSWorkspace.shared.activateFileViewerSelecting([url])
                        }
                        .buttonStyle(.link)
                    }
                }
                if let error = state.databaseError {
                    Text("数据库打不开，当前不会保存：\(error)").foregroundStyle(.red)
                }
                HStack {
                    Button("导出数据库…") { export() }
                    Spacer()
                    Button("删除今天的数据…", role: .destructive) { confirmDeleteToday = true }
                    Button("删除全部数据…", role: .destructive) { confirmDeleteAll = true }
                }
                if let message { Text(message).font(.caption).foregroundStyle(Theme.secondary) }
            }

            Section("高级") {
                Toggle("在侧栏显示信号实验室", isOn: $state.showLab)
                Text("信号实验室用于验证采集信号（按键重复、触控板压力、时间戳单位、输入源）。录制协议期间的输入不计入统计。")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("设置")
        .confirmationDialog("删除今天的全部记录？", isPresented: $confirmDeleteToday) {
            Button("删除今天", role: .destructive) { run(done: "已删除今天的数据") { try $0.delete(day: .today()) } }
        } message: { Text("此操作不能撤销。") }
        .confirmationDialog("删除全部记录？", isPresented: $confirmDeleteAll) {
            Button("全部删除", role: .destructive) { run(done: "已删除全部数据") { try $0.deleteAll() } }
        } message: { Text("包括导入的旧版数据（原 JSON 文件不受影响）。此操作不能撤销。") }
    }

    private func run(done: String, _ action: (InputscapeDatabase) throws -> Void) {
        guard let database else { return }
        do {
            capture.flush()
            try action(database)
            message = done
        } catch {
            message = "失败：\(error.localizedDescription)"
        }
    }

    private func export() {
        guard let database else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "inputscape-\(LogicalDay.today().id).sqlite"
        panel.allowedContentTypes = [UTType(filenameExtension: "sqlite") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try database.export(to: url)
            message = "已导出到 \(url.lastPathComponent)"
        } catch {
            message = "导出失败：\(error.localizedDescription)"
        }
    }
}
