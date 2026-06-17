import Foundation

/// 连接页用的内核运行态：当前模式 + 实时上下行速率。
/// 经 **sendProviderMessage IPC**：模式 getMode/setMode，速率 traffic（内核每秒速率直给）。
@MainActor
final class KernelController: ObservableObject {

    /// 全局共享：由 RootView 按连接状态驱动启停，不随页面出现/消失，切 tab 后数据不清零。
    static let shared = KernelController()

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

    /// 一条速率采样（用于曲线图）。
    struct TrafficSample: Identifiable {
        let id: Int        // 单调递增序号，作 x 轴
        let up: Int64
        let down: Int64
    }

    @Published var mode: Mode = .rule
    @Published var up: Int64 = 0
    @Published var down: Int64 = 0
    @Published var reachable = false
    /// 最近若干秒的速率采样（曲线图数据）。
    @Published private(set) var samples: [TrafficSample] = []

    private var trafficTask: Task<Void, Never>?
    private var sampleIndex = 0
    private let maxSamples = 60

    /// 连接建立后调用：读模式 + 开始速率采样。
    func start() {
        Task { await loadMode() }
        startTraffic()
    }

    /// 断开后调用：停止采样。
    func stop() { stopTraffic() }

    /// 读取当前模式（IPC getMode，连通即标记 reachable）。
    func loadMode() async {
        let result = await CoreStateManager.shared.sendMessage(["cmd": "getMode"])
        switch result {
        case .ok(let data):
            let m = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            mode = Mode(rawValue: m) ?? .rule
            reachable = true
        case .failure:
            reachable = false
        }
    }

    /// 切换模式（IPC setMode，乐观更新 + 失败回滚）。
    func setMode(_ newMode: Mode) async {
        let old = mode
        mode = newMode
        let result = await CoreStateManager.shared.sendMessage(["cmd": "setMode", "mode": newMode.rawValue])
        if case .failure = result { mode = old }
    }

    /// 开始速率轮询（连接后调用）。每秒 IPC traffic，内核直接给每秒速率，无需差值计算。
    func startTraffic() {
        stopTraffic()
        trafficTask = Task { [weak self] in
            while !Task.isCancelled {
                let result = await CoreStateManager.shared.sendMessage(["cmd": "traffic"])
                if case .ok(let data) = result,
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let u = (obj["up"] as? NSNumber)?.int64Value ?? 0
                    let d = (obj["down"] as? NSNumber)?.int64Value ?? 0
                    self?.up = u
                    self?.down = d
                    self?.pushSample(up: u, down: d)
                    self?.reachable = true
                } else {
                    self?.reachable = false
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 停止速率轮询（断开/页面消失）。
    func stopTraffic() {
        trafficTask?.cancel()
        trafficTask = nil
        up = 0
        down = 0
        samples.removeAll()
        sampleIndex = 0
    }

    private func pushSample(up: Int64, down: Int64) {
        samples.append(TrafficSample(id: sampleIndex, up: up, down: down))
        sampleIndex += 1
        if samples.count > maxSamples { samples.removeFirst(samples.count - maxSamples) }
    }
}
