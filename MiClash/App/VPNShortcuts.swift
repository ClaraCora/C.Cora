import AppIntents

// 快捷指令（App Shortcuts）：连接 / 断开 MiClash。
// 意图在主 App 进程里执行（有 networkextension 权限可启停隧道），执行后通过
// CoreStateManager.connect()/disconnect() 顺带写共享状态 + 刷新控制中心磁贴。
// 不设 openAppWhenRun —— 后台执行即可，不强制把 App 拉到前台。

struct ConnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "连接 MiClash"
    static let description = IntentDescription("开启 MiClash 代理")

    @MainActor
    func perform() async throws -> some IntentResult {
        await CoreStateManager.shared.connect()
        return .result()
    }
}

struct DisconnectVPNIntent: AppIntent {
    static let title: LocalizedStringResource = "断开 MiClash"
    static let description = IntentDescription("关闭 MiClash 代理")

    @MainActor
    func perform() async throws -> some IntentResult {
        CoreStateManager.shared.disconnect()
        return .result()
    }
}

struct ToggleVPNShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "切换 MiClash"
    static let description = IntentDescription("在连接 / 断开之间切换 MiClash 代理")

    @MainActor
    func perform() async throws -> some IntentResult {
        await CoreStateManager.shared.toggleConnection()
        return .result()
    }
}

/// 把上面的意图注册成系统快捷指令（Shortcuts App / Siri / 自动化里可用）。
struct MiClashShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ConnectVPNIntent(),
            phrases: ["用 \(.applicationName) 连接", "开启 \(.applicationName)"],
            shortTitle: "连接",
            systemImageName: "shield.lefthalf.filled"
        )
        AppShortcut(
            intent: DisconnectVPNIntent(),
            phrases: ["断开 \(.applicationName)", "关闭 \(.applicationName)"],
            shortTitle: "断开",
            systemImageName: "shield.slash"
        )
        AppShortcut(
            intent: ToggleVPNShortcutIntent(),
            phrases: ["切换 \(.applicationName)"],
            shortTitle: "切换",
            systemImageName: "shield.righthalf.filled"
        )
    }
}
