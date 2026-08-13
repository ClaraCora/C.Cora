import SwiftUI

/// 活动连接是底栏固定入口；日志保留在同一工作区内，避免底栏超过五项。
struct ActivityView: View {
    @EnvironmentObject private var core: CoreStateManager
    @State private var selection: ActivitySection = .connections
    @StateObject private var connections = ConnectionsController()

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                VStack(spacing: 0) {
                    Picker("连接页面", selection: $selection) {
                        ForEach(ActivitySection.allCases) { section in
                            Label(section.title, systemImage: section.systemImage)
                                .tag(section)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)

                    Group {
                        switch selection {
                        case .connections:
                            ConnectionsView(controller: connections)
                        case .logs:
                            LogsView()
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .task(id: core.isActive) {
            guard core.isActive else {
                connections.reset()
                return
            }
            await connections.poll()
        }
    }
}

private enum ActivitySection: String, CaseIterable, Identifiable {
    case connections
    case logs

    var id: Self { self }

    var title: String {
        switch self {
        case .connections: return "记录"
        case .logs: return "日志"
        }
    }

    var systemImage: String {
        switch self {
        case .connections: return "clock.arrow.circlepath"
        case .logs: return "list.bullet.rectangle"
        }
    }
}
