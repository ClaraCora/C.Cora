import SwiftUI
import UIKit

enum SettingsCategory {
    case configuration, resources, graphite, rules, privacy, speed, scripts

    var color: Color {
        switch self {
        case .configuration: return Color(uiColor: .systemBlue)
        case .resources: return Color(uiColor: .systemCyan)
        case .graphite: return Color(uiColor: .systemGray)
        case .rules: return Color(uiColor: .systemGreen)
        case .privacy: return Color(uiColor: .systemTeal)
        case .speed: return Color(uiColor: .systemOrange)
        case .scripts: return Color(uiColor: .systemPink)
        }
    }

    var iconForeground: Color {
        switch self {
        case .resources, .rules, .privacy, .speed: return .black.opacity(0.85)
        case .configuration, .graphite, .scripts: return .white
        }
    }
}

private struct SettingsAppearanceKey: EnvironmentKey {
    static let defaultValue = false
}

private struct SettingsCategoryKey: EnvironmentKey {
    static let defaultValue = SettingsCategory.configuration
}

private struct SettingsIconPressedKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    // Scope shared backgrounds to the settings navigation tree, including sheets.
    var coraSettingsAppearance: Bool {
        get { self[SettingsAppearanceKey.self] }
        set { self[SettingsAppearanceKey.self] = newValue }
    }

    var settingsCategory: SettingsCategory {
        get { self[SettingsCategoryKey.self] }
        set { self[SettingsCategoryKey.self] = newValue }
    }

    var settingsIconPressed: Bool {
        get { self[SettingsIconPressedKey.self] }
        set { self[SettingsIconPressedKey.self] = newValue }
    }
}

struct SettingsPressStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.45)
            .environment(\.settingsIconPressed, configuration.isPressed)
            .background(Color.primary.opacity(configuration.isPressed ? 0.06 : 0),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12),
                       value: configuration.isPressed)
    }
}

private struct SettingsChangeAnimation<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let value: Value

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: value)
    }
}

/// A stable accessory slot; success is emitted only by a completed user action.
struct SettingsActivityIndicator: View {
    let isRunning: Bool
    var successToken = 0
    var idleSystemImage: String? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsSuccess = false
    @State private var presentedToken = 0
    @ScaledMetric(relativeTo: .body) private var size: CGFloat = 22

    var body: some View {
        ZStack {
            if let idleSystemImage {
                Image(systemName: idleSystemImage)
                    .opacity(!showsSuccess && !isRunning ? 1 : 0)
            }
            successSymbol
                .symbolRenderingMode(.palette)
                .foregroundStyle(Color.black.opacity(0.85), Color(uiColor: .systemGreen))
                .opacity(showsSuccess && !isRunning ? 1 : 0)
            if isRunning {
                ProgressView().controlSize(.small)
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isRunning ? "正在处理" : "已完成")
        .accessibilityHidden(!isRunning && !showsSuccess)
        .settingsChangeAnimation(value: showsSuccess)
        .onChange(of: isRunning) { running in
            if running { showsSuccess = false }
        }
        .task(id: successToken) {
            showsSuccess = false
            guard successToken > 0, successToken != presentedToken else { return }
            presentedToken = successToken
            showsSuccess = true
            do {
                try await Task.sleep(nanoseconds: 1_600_000_000)
            } catch {
                return
            }
            showsSuccess = false
        }
        .onDisappear { showsSuccess = false }
    }

    @ViewBuilder private var successSymbol: some View {
        if #available(iOS 17.0, *), !reduceMotion {
            Image(systemName: "checkmark.circle.fill")
                .symbolEffect(.bounce, value: successToken)
        } else {
            Image(systemName: "checkmark.circle.fill")
        }
    }
}

extension View {
    func settingsSectionStyle() -> some View {
        listRowBackground(AppListRowBackground())
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
    }

    func settingsChangeAnimation<Value: Equatable>(value: Value) -> some View {
        modifier(SettingsChangeAnimation(value: value))
    }
}
