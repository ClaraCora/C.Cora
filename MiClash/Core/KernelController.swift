import Foundation

/// 连接页用的内核运行态：当前模式 + 实时上下行速率。
/// 经 external-controller：模式 GET/PATCH /configs，速率订阅 /traffic 流。
@MainActor
final class KernelController: ObservableObject {

    enum Mode: String, CaseIterable, Identifiable {
        case rule, global, direct
        var id: String { rawValue }
        var label: String {
            switch self {
            case .rule: return "规则"
            case .global: return "全局"
            case .direct: return "直连"
            }
        }
    }

    @Published var mode: Mode = .rule
    @Published var up: Int64 = 0
    @Published var down: Int64 = 0
    @Published var reachable = false

    private let stream = MihomoStream()

    /// 读取当前模式（连通即标记 reachable）。
    func loadMode() async {
        do {
            let m = try await MihomoAPI.currentMode()
            mode = Mode(rawValue: m) ?? .rule
            reachable = true
        } catch {
            reachable = false
        }
    }

    /// 切换模式（乐观更新 + 回读确认）。
    func setMode(_ newMode: Mode) async {
        let old = mode
        mode = newMode
        do {
            try await MihomoAPI.setMode(newMode.rawValue)
        } catch {
            mode = old // 失败回滚
        }
    }

    /// 开始订阅速率流（连接后调用）。
    func startTraffic() {
        stream.onObject = { [weak self] obj in
            let up = (obj["up"] as? NSNumber)?.int64Value ?? 0
            let down = (obj["down"] as? NSNumber)?.int64Value ?? 0
            Task { @MainActor in
                self?.up = up
                self?.down = down
                self?.reachable = true
            }
        }
        stream.start(path: "traffic")
    }

    /// 停止速率流（断开/页面消失）。
    func stopTraffic() {
        stream.stop()
        up = 0
        down = 0
    }
}
