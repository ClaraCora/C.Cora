import SwiftUI

/// 日志页：实时显示 mihomo 内核日志（external-controller /logs 流）。
/// 顶部可切过滤级别；右下悬浮按钮可暂停/恢复自动滚动并随时跳到最新。
struct LogsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var controller: LogStreamController

    @State private var autoScroll = true

    var body: some View {
        NavigationStack {
            Group {
                if !core.isActive {
                    ContentUnavailableView("未连接",
                        systemImage: "doc.text.magnifyingglass",
                        description: Text("先连接 VPN 才能查看内核日志"))
                } else if let err = controller.error, controller.lines.isEmpty {
                    ContentUnavailableView("暂无日志", systemImage: "doc.text",
                        description: Text(err))
                } else {
                    logList
                }
            }
            .floatingTabBarInset()
            .navigationTitle("日志")
            .searchable(text: $controller.searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索日志")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("级别", selection: Binding(
                            get: { controller.level },
                            set: { controller.setLevel($0) }
                        )) {
                            ForEach(SettingsStore.logLevelOptions, id: \.self) { Text($0).tag($0) }
                        }
                    } label: {
                        Label(controller.level, systemImage: "line.3.horizontal.decrease.circle")
                            .font(.subheadline)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.clear() } label: { Image(systemName: "trash") }
                        .disabled(controller.lines.isEmpty)
                }
            }
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(controller.lines) { line in
                        LogRow(line: line)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.visible)
            .overlay(alignment: .bottomTrailing) {
                scrollControl(proxy)
            }
            .onChange(of: controller.lines.count) { _, _ in
                guard autoScroll, let last = controller.lines.last else { return }
                withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onAppear {
                if let last = controller.lines.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }

    /// 暂停/恢复自动滚动 + 跳到最新。
    private func scrollControl(_ proxy: ScrollViewProxy) -> some View {
        HStack(spacing: 10) {
            if !autoScroll {
                Button {
                    if let last = controller.lines.last {
                        withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                    }
                } label: {
                    Image(systemName: "arrow.down.to.line")
                        .font(.system(size: 16, weight: .semibold))
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
            }
            Button {
                autoScroll.toggle()
                if autoScroll, let last = controller.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            } label: {
                Image(systemName: autoScroll ? "pause.fill" : "play.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(14)
                    .background(autoScroll ? Color.orange : Color.green, in: Circle())
                    .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
            }
        }
        .padding(.trailing, 16)
        .padding(.bottom, 16)
    }
}

/// 单条日志：级别色块 + 时间 + 正文。
private struct LogRow: View {
    let line: LogLine

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(line.type.uppercased())
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.white)
                .frame(width: 52)
                .padding(.vertical, 3)
                .background(levelColor, in: RoundedRectangle(cornerRadius: 5, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                Text(line.payload)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(line.time, format: .dateTime.hour().minute().second())
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var levelColor: Color {
        switch line.type.lowercased() {
        case "error":             return .red
        case "warning", "warn":   return .orange
        case "debug":             return .gray
        default:                  return .blue
        }
    }
}
