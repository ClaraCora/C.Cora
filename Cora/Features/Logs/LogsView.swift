import SwiftUI
import UIKit

/// 实时内核日志。断开后继续显示上一会话，直到用户清空或下一次连接开始。
struct LogsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var controller: LogStreamController

    @State private var autoScroll = true
    @State private var pausedAtLineCount = 0
    @State private var isCopyingDiagnostic = false
    @State private var didCopyDiagnostic = false
    @State private var isExportingLog = false
    @State private var exportedLogURL: URL?
    @State private var exportError: String?

    var body: some View {
        content
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $controller.searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索日志")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    levelMenu
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button { copyDiagnostic() } label: {
                        Image(systemName: didCopyDiagnostic ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(isCopyingDiagnostic)
                    .accessibilityLabel(didCopyDiagnostic ? "诊断已复制" : "复制内存诊断")

                    Button { exportNELog() } label: {
                        Image(systemName: isExportingLog ? "hourglass" : "square.and.arrow.up")
                    }
                    .disabled(isExportingLog)
                    .accessibilityLabel("导出 NE 日志")

                    Button { controller.clear() } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!controller.hasBufferedLines)
                    .accessibilityLabel("清空日志")
                }
            }
            .sheet(isPresented: Binding(
                get: { exportedLogURL != nil },
                set: { if !$0 { exportedLogURL = nil } }
            )) {
                if let url = exportedLogURL {
                    LogShareSheet(url: url)
                        .presentationDetents([.medium, .large])
                }
            }
            .alert("导出失败", isPresented: Binding(
                get: { exportError != nil },
                set: { if !$0 { exportError = nil } }
            )) {
                Button("好", role: .cancel) { exportError = nil }
            } message: {
                Text(exportError ?? "未知错误")
            }
    }

    private func copyDiagnostic() {
        guard !isCopyingDiagnostic else { return }
        isCopyingDiagnostic = true
        Task { @MainActor in
            UIPasteboard.general.string = await core.fetchLogs()
            isCopyingDiagnostic = false
            didCopyDiagnostic = true
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            didCopyDiagnostic = false
        }
    }

    private func exportNELog() {
        guard !isExportingLog else { return }
        isExportingLog = true
        Task { @MainActor in
            let text = await core.exportNELog()
            isExportingLog = false
            guard !text.hasPrefix("NE 日志导出失败：") else {
                exportError = text
                return
            }
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("Cora-ne-log-\(stamp).log")
            do {
                try Data(text.utf8).write(to: url, options: .atomic)
                exportedLogURL = url
            } catch {
                exportError = "无法创建日志备份：\(error.localizedDescription)"
            }
        }
    }

    @ViewBuilder private var content: some View {
        if !controller.lines.isEmpty {
            VStack(spacing: 0) {
                if !controller.isStreaming || controller.isAwaitingNewSession {
                    previousSessionHeader
                }
                logList
            }
        } else if controller.hasBufferedLines {
            VStack(spacing: 0) {
                if !controller.isStreaming || controller.isAwaitingNewSession {
                    previousSessionHeader
                }
                if controller.searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    CoraUnavailableState("当前级别无日志",
                                         systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    CoraSearchUnavailableState(query: controller.searchText)
                }
            }
        } else if core.isActive && controller.error == nil {
            ProgressView("等待内核日志…")
        } else if let error = controller.error {
            CoraUnavailableState("暂无日志", systemImage: "doc.text", description: error)
        } else {
            CoraUnavailableState("暂无日志", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var levelMenu: some View {
        Menu {
            Picker("级别", selection: Binding(
                get: { controller.level },
                set: { controller.setLevel($0) }
            )) {
                ForEach(SettingsStore.logLevelOptions, id: \.self) {
                    Text(logLevelTitle($0)).tag($0)
                }
            }
        } label: {
            Label(logLevelTitle(controller.level), systemImage: "line.3.horizontal.decrease.circle")
                .font(.subheadline)
        }
    }

    private var previousSessionHeader: some View {
        HStack(spacing: 7) {
            Image(systemName: "clock.arrow.circlepath")
            Text("上次连接")
                .fontWeight(.medium)
            Spacer()
            Text("\(controller.bufferedLineCount) 条")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .coraGlassSurface(cornerRadius: 14)
        .padding(.horizontal, 14)
        .accessibilityElement(children: .combine)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            trackManualScrolling(
                List(controller.lines) { line in
                    LogRow(line: line)
                        .id(line.id)
                        .listRowInsets(EdgeInsets(top: 3, leading: 0, bottom: 3, trailing: 0))
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .overlay(alignment: .bottomTrailing) {
                    scrollControl(proxy)
                }
            )
            .onChange(of: controller.lines.last?.id) { id in
                guard autoScroll, let id else { return }
                proxy.scrollTo(id, anchor: .bottom)
            }
            .onAppear {
                if let last = controller.lines.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func trackManualScrolling<Content: View>(_ content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.onScrollPhaseChange { _, phase in
                if phase.isScrolling && phase != .animating {
                    pauseAutoScroll()
                }
            }
        } else {
            content.simultaneousGesture(
                DragGesture(minimumDistance: 4).onChanged { _ in
                    pauseAutoScroll()
                }
            )
        }
    }

    private func scrollControl(_ proxy: ScrollViewProxy) -> some View {
        Group {
            if !autoScroll {
                Button {
                    autoScroll = true
                    pausedAtLineCount = controller.bufferedLineCount
                    guard let last = controller.lines.last else { return }
                    withAnimation(.easeOut(duration: 0.18)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                } label: {
                    ZStack(alignment: .topTrailing) {
                        Image(systemName: "arrow.down.to.line")
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                        if pausedLineCount > 0 {
                            Text(pausedLineCount > 99 ? "99+" : String(pausedLineCount))
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 4)
                                .frame(minWidth: 16, minHeight: 16)
                                .background(Color.red, in: Capsule())
                        }
                    }
                }
                .accessibilityLabel("跳到最新日志并恢复自动滚动")
            }
        }
        .padding(.trailing, 14)
        .padding(.bottom, 12)
    }

    private var pausedLineCount: Int {
        max(0, controller.bufferedLineCount - pausedAtLineCount)
    }

    private func pauseAutoScroll() {
        guard autoScroll else { return }
        pausedAtLineCount = controller.bufferedLineCount
        autoScroll = false
    }
}

private struct LogShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

/// 紧凑的两层记录行：保持列表滚动成本低，全文在详情页按需显示。
private struct LogRow: View {
    let line: LogLine

    var body: some View {
        NavigationLink {
            LogDetailView(line: line)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    Circle()
                        .fill(levelColor)
                        .frame(width: 8, height: 8)
                    Text(logLevelTitle(line.type))
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(levelColor)
                    Spacer(minLength: 0)
                    Text(line.time, format: .dateTime.hour().minute().second())
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }

                Text(line.payload)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .coraListRowSurface(tint: levelColor, verticalPadding: 7)
        .contentShape(Rectangle())
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
    }

    private var levelColor: Color {
        logLevelColor(line.type)
    }
}

private struct LogDetailView: View {
    let line: LogLine

    var body: some View {
        List {
            Section {
                HStack(spacing: 7) {
                    Circle().fill(levelColor).frame(width: 8, height: 8)
                    Text(logLevelTitle(line.type))
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text(line.time, format: .dateTime.hour().minute().second())
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .coraGlassSurface(tint: levelColor)
            }
            .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 8, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)

            Section("日志内容") {
                Text(line.payload)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
                    .coraGlassSurface()
            }
            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(AppAmbientBackground())
        .navigationTitle("日志详情")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button {
                    UIPasteboard.general.string = line.payload
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("复制日志")
            }
        }
    }

    private var levelColor: Color {
        logLevelColor(line.type)
    }
}

private func logLevelTitle(_ rawLevel: String) -> String {
    switch rawLevel.lowercased() {
    case "error": return "错误"
    case "warning", "warn": return "警告"
    case "debug": return "调试"
    case "info": return "信息"
    case "silent": return "静默"
    case "wrap": return "会话"
    default: return rawLevel.uppercased()
    }
}

private func logLevelColor(_ rawLevel: String) -> Color {
    switch rawLevel.lowercased() {
    case "error": return .red
    case "warning", "warn": return .orange
    case "debug": return .gray
    case "wrap": return .purple
    default: return .blue
    }
}
