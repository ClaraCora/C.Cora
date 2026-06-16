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

    private var trafficTask: Task<Void, Never>?

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
        guard trafficTask == nil else { return }
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let stream = try await MihomoAPI.lineStream(path: "traffic")
                    self?.reachable = true
                    for try await obj in stream {
                        if Task.isCancelled { break }
                        let up = (obj["up"] as? NSNumber)?.int64Value ?? 0
                        let down = (obj["down"] as? NSNumber)?.int64Value ?? 0
                        self?.up = up
                        self?.down = down
                    }
                } catch {
                    // 断流（如刚连上内核还没起）：稍后重试
                    self?.reachable = false
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                }
            }
        }
    }

    /// 停止速率流（断开/页面消失）。
    func stopTraffic() {
        trafficTask?.cancel()
        trafficTask = nil
        up = 0
        down = 0
    }
}
