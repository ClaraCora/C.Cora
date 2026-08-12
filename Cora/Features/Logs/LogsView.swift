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

    var body: some View {
        content
            .navigationTitle("日志")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $controller.searchText,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "搜索日志")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    levelMenu
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { copyDiagnostic() } label: {
                        Image(systemName: didCopyDiagnostic ? "checkmark" : "doc.on.doc")
                    }
                    .disabled(isCopyingDiagnostic)
                    .accessibilityLabel(didCopyDiagnostic ? "诊断已复制" : "复制内存诊断")

                    Button { controller.clear() } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!controller.hasBufferedLines)
                    .accessibilityLabel("清空日志")
                }
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
                    ContentUnavailableView("当前级别无日志",
                                           systemImage: "line.3.horizontal.decrease.circle")
                } else {
                    ContentUnavailableView.search(text: controller.searchText)
                }
            }
        } else if core.isActive && controller.error == nil {
            ProgressView("等待内核日志…")
        } else if let error = controller.error {
            ContentUnavailableView("暂无日志", systemImage: "doc.text",
                                   description: Text(error))
        } else {
            ContentUnavailableView("暂无日志", systemImage: "doc.text.magnifyingglass")
        }
    }

    private var levelMenu: some View {
        Menu {
            Picker("级别", selection: Binding(
                get: { controller.level },
                set: { controller.setLevel($0) }
            )) {
                ForEach(SettingsStore.logLevelOptions, id: \.self) {
                    Text($0.uppercased()).tag($0)
                }
            }
        } label: {
            Label(controller.level.uppercased(), systemImage: "line.3.horizontal.decrease.circle")
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
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(.thinMaterial)
        .accessibilityElement(children: .combine)
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            trackManualScrolling(
                List(controller.lines) { line in
                    LogRow(line: line)
                        .id(line.id)
                        .listRowInsets(EdgeInsets(top: 6, leading: 14, bottom: 6, trailing: 12))
                        .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(Color.clear)
                .overlay(alignment: .bottomTrailing) {
                    scrollControl(proxy)
                }
            )
            .onChange(of: controller.lines.last?.id) { _, id in
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

/// 轻量控制台行：避免每条日志的卡片、阴影和全文选择参与滚动布局。
private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            RoundedRectangle(cornerRadius: 1)
                .fill(levelColor)
                .frame(width: 3, height: 15)

            Text(line.time, format: .dateTime.hour().minute().second())
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
                .frame(width: 54, alignment: .leading)

            Text(line.type.uppercased())
                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                .foregroundStyle(levelColor)
                .frame(width: 48, alignment: .leading)

            Text(line.payload)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button {
                UIPasteboard.general.string = line.payload
            } label: {
                Label("复制日志", systemImage: "doc.on.doc")
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var levelColor: Color {
        switch line.type.lowercased() {
        case "error": return .red
        case "warning", "warn": return .orange
        case "debug": return .gray
        default: return .blue
        }
    }
}
