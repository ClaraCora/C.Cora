import SwiftUI
import UIKit

/// 按需开启的 NE 内存诊断。默认关闭时不创建采样器，也不向 App 缓冲诊断历史。
struct DeveloperDiagnosticsView: View {
    @EnvironmentObject private var settings: SettingsStore
    @EnvironmentObject private var core: CoreStateManager
    @State private var rawDiagnostics = ""
    @State private var report = "尚未读取诊断。"
    @State private var isLoading = false
    @State private var statusMessage: String?
    @State private var copied = false

    private var developerModeBinding: Binding<Bool> {
        Binding(
            get: { settings.developerMode },
            set: { enabled in
                settings.developerMode = enabled
                if !enabled {
                    rawDiagnostics = ""
                    report = "尚未读取诊断。"
                    statusMessage = nil
                }
                guard core.isActive else { return }
                Task {
                    let ok = await core.setMemoryDiagnostics(enabled)
                    if !ok {
                        statusMessage = "当前隧道未接受开发者诊断切换，请重新连接 VPN。"
                    }
                }
            })
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: developerModeBinding) {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("开发者模式")
                                .font(.body.weight(.medium))
                            Text("只在需要排查 NE 内存问题时开启")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        SettingsSymbol(systemImage: "wrench.and.screwdriver")
                    }
                }
                .tint(.accentColor)
            } footer: {
                Text("开启后每 5 秒记录一次物理内存、Go 堆、连接和 goroutine 快照，最多保留 256KB。关闭后不会持续采样；诊断数据可能包含连接数量等运行态信息。")
            }
            .listRowBackground(AppListRowBackground())

            if settings.developerMode {
                Section("内存诊断") {
                    HStack(spacing: 12) {
                        Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "waveform.path.ecg")
                            .foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(core.isActive ? "正在运行" : "等待 VPN 连接")
                                .font(.body.weight(.medium))
                            Text("采样在 NE 内完成，分析在 App 内进行")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if isLoading { ProgressView().controlSize(.small) }
                    }

                    Button {
                        Task { await loadDiagnostics() }
                    } label: {
                        Label("读取并分析", systemImage: "chart.bar.xaxis")
                    }
                    .disabled(isLoading || !core.isActive)

                    Button {
                        copyRawDiagnostics()
                    } label: {
                        Label(copied ? "已复制原始采样" : "复制原始采样", systemImage: copied ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(rawDiagnostics.isEmpty || isLoading)

                    Button(role: .destructive) {
                        Task { await clearDiagnostics() }
                    } label: {
                        Label("清理诊断文件", systemImage: "trash")
                    }
                    .disabled(isLoading || !core.isActive)
                }
                .listRowBackground(AppListRowBackground())

                Section("分析结果") {
                    Text(report)
                        .font(.footnote.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 4)
                }
                .listRowBackground(AppListRowBackground())
            }

            if let statusMessage {
                Section {
                    Label(statusMessage, systemImage: "info.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .listRowBackground(AppListRowBackground())
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .listStyle(.insetGrouped)
        .listSectionSpacing(18)
        .listRowSeparatorTint(Color.primary.opacity(0.08))
        .navigationTitle("开发者模式")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard settings.developerMode, core.isActive else { return }
            await loadDiagnostics()
        }
    }

    private func loadDiagnostics() async {
        guard !isLoading else { return }
        isLoading = true
        statusMessage = nil
        let text = await core.fetchMemoryDiagnostics()
        guard !Task.isCancelled else { isLoading = false; return }
        rawDiagnostics = text
        report = MemoryDiagnosticAnalyzer.analyze(text)
        isLoading = false
    }

    private func copyRawDiagnostics() {
        guard !rawDiagnostics.isEmpty else { return }
        UIPasteboard.general.string = rawDiagnostics
        copied = true
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            copied = false
        }
    }

    private func clearDiagnostics() async {
        isLoading = true
        let result = await core.clearMemoryDiagnostics()
        isLoading = false
        switch result {
        case .success:
            rawDiagnostics = ""
            report = "诊断文件已清理。保持 VPN 运行一段时间后可重新读取。"
            statusMessage = nil
        case .failure(let error):
            statusMessage = error.localizedDescription
        }
    }
}
