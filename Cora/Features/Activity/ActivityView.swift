import SwiftUI

/// 活动连接是底栏固定入口；日志保留在同一工作区内，避免底栏超过五项。
struct ActivityView: View {
    @State private var selection: ActivitySection = .connections
    @ObservedObject var connections: ConnectionsController

    var body: some View {
        NavigationStack {
            ZStack {
                AppAmbientBackground()
                VStack(spacing: 0) {
                    ActivitySectionControl(selection: $selection)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)

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
    }
}

private struct ActivitySectionControl: View {
    @Binding var selection: ActivitySection

    var body: some View {
        HStack(spacing: 4) {
            ForEach(ActivitySection.allCases) { section in
                Button {
                    selection = section
                } label: {
                    Label(section.title, systemImage: section.systemImage)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(selection == section ? .white : .primary)
                        .frame(maxWidth: .infinity)
                        // Keep both segmented controls at the iOS minimum
                        // hit target without changing their shared padding.
                        .frame(minHeight: 44)
                        .background {
                            if selection == section {
                                LinearGradient(colors: [.blue, .cyan],
                                               startPoint: .topLeading,
                                               endPoint: .bottomTrailing)
                                    .overlay(.ultraThinMaterial.opacity(0.12))
                                    .clipShape(Capsule())
                            }
                        }
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == section ? .isSelected : [])
            }
        }
        .padding(4)
        .background(.thinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.30), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
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
