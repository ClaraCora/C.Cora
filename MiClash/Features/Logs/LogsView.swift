import SwiftUI

/// 日志页：实时显示 mihomo 内核日志（经 external-controller /logs 流）。
struct LogsView: View {
    @EnvironmentObject private var core: CoreStateManager
    @EnvironmentObject private var controller: LogStreamController

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
            .navigationTitle("日志")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { controller.clear() } label: { Image(systemName: "trash") }
                        .disabled(controller.lines.isEmpty)
                }
            }
            // 启停由 RootView 按连接状态统一驱动，这里只展示，切走再回来日志不清空。
        }
    }

    private var logList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(controller.lines) { line in
                        HStack(alignment: .top, spacing: 8) {
                            Text(line.type.uppercased())
                                .font(.system(size: 9, weight: .bold, design: .monospaced))
                                .foregroundStyle(color(for: line.type))
                                .frame(width: 52, alignment: .leading)
                            Text(line.payload)
                                .font(.system(.caption2, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id(line.id)
                    }
                }
                .padding(.horizontal)
                .padding(.vertical, 8)
            }
            .onChange(of: controller.lines.count) { _, _ in
                if let last = controller.lines.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
    }

    private func color(for type: String) -> Color {
        switch type.lowercased() {
        case "error": return .red
        case "warning": return .orange
        case "debug": return .secondary
        default: return .blue
        }
    }
}
