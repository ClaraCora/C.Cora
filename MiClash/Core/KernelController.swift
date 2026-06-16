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

    /// 开始速率轮询（连接后调用）。每秒 GET /connections，用累计字节差值算速率。
    /// 走普通 GET 而非 WebSocket——后者在重签环境下几秒就断，轮询稳定可靠。
    func startTraffic() {
        stopTraffic()
        trafficTask = Task { [weak self] in
            var prevDown: Int64?
            var prevUp: Int64?
            var prevTime = Date()
            while !Task.isCancelled {
                do {
                    let (d, u) = try await MihomoAPI.connectionsTotals()
                    let now = Date()
                    if let pd = prevDown, let pu = prevUp {
                        let dt = max(now.timeIntervalSince(prevTime), 0.001)
                        let downRate = max(0, Int64(Double(d - pd) / dt))
                        let upRate = max(0, Int64(Double(u - pu) / dt))
                        self?.down = downRate
                        self?.up = upRate
                        self?.pushSample(up: upRate, down: downRate)
                    }
                    prevDown = d
                    prevUp = u
                    prevTime = now
                    self?.reachable = true
                } catch {
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
