import Foundation

/// 连接页用的内核运行态：当前模式 + 实时上下行速率 + NE 进程 phys_footprint。
/// 经 **sendProviderMessage IPC**：模式 getMode/setMode、速率 traffic、内存 memory。
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
    struct TrafficSample: Identifiable, Equatable {
        let id: Int        // 单调递增序号，作 x 轴
        let up: Int64
        let down: Int64
    }

    struct RuntimeSnapshot: Equatable {
        let up: Int64
        let down: Int64
        let uptime: Int64
        let samples: [TrafficSample]

        static let empty = RuntimeSnapshot(up: 0, down: 0, uptime: 0, samples: [])
    }

    @Published var mode: Mode = .rule
    @Published private(set) var runtime = RuntimeSnapshot.empty
    @Published private(set) var reachable = false
    /// Packet Tunnel Extension 进程的物理内存占用（task_vm_info.phys_footprint，字节）。
    @Published private(set) var memoryFootprint: Int64?
    /// 最近若干秒的速率采样（曲线图数据）。
    var up: Int64 { runtime.up }
    var down: Int64 { runtime.down }
    var uptime: Int64 { runtime.uptime }
    var samples: [TrafficSample] { runtime.samples }

    private var trafficTask: Task<Void, Never>?
    private var memoryTask: Task<Void, Never>?
    private var memoryRefreshTask: Task<Int64?, Never>?
    private var memoryRefreshGeneration = 0
    private var modeTask: Task<Void, Never>?
    private var sampleIndex = 0
    private let maxSamples = 60

    /// 连接建立后调用：读模式 + 开始速率/内存采样。
    func start() {
        if modeTask == nil {
            modeTask = Task { [weak self] in await self?.loadMode() }
        }
        if trafficTask == nil { startTraffic() }
        if memoryTask == nil { startMemoryPolling() }
    }

    /// 断开后调用：停止采样。
    func stop() {
        modeTask?.cancel()
        modeTask = nil
        stopTraffic()
        stopMemoryPolling()
        setReachable(false)
    }

    /// 读取当前模式（IPC getMode，连通即标记 reachable）。
    func loadMode() async {
        let result = await CoreStateManager.shared.sendMessage(["cmd": "getMode"])
        guard !Task.isCancelled else { return }
        switch result {
        case .ok(let data):
            let m = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let loadedMode = Mode(rawValue: m) ?? .rule
            if mode != loadedMode { mode = loadedMode }
            setReachable(true)
        case .failure:
            setReachable(false)
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
                guard !Task.isCancelled else { return }
                if case .ok(let data) = result,
                   let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
                    let u = (obj["up"] as? NSNumber)?.int64Value ?? 0
                    let d = (obj["down"] as? NSNumber)?.int64Value ?? 0
                    let uptime = (obj["uptime"] as? NSNumber)?.int64Value ?? 0
                    self?.pushSample(up: u, down: d, uptime: uptime)
                    self?.setReachable(true)
                } else {
                    self?.setReachable(false)
                }
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    /// 停止速率轮询（断开/页面消失）。
    func stopTraffic() {
        trafficTask?.cancel()
        trafficTask = nil
        if runtime != .empty { runtime = .empty }
        sampleIndex = 0
    }

    /// 立即读取一次内存；前台恢复时调用，避免等待轮询周期才显示数值。
    @discardableResult
    func refreshMemory() async -> Bool {
        let task: Task<Int64?, Never>
        let generation: Int
        if let current = memoryRefreshTask {
            task = current
            generation = memoryRefreshGeneration
        } else {
            memoryRefreshGeneration &+= 1
            generation = memoryRefreshGeneration
            task = Task {
                let result = await CoreStateManager.shared.sendMessage(["cmd": "memory"])
                guard !Task.isCancelled,
                      case .ok(let data) = result,
                      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      let footprint = (object["physFootprint"] as? NSNumber)?.int64Value,
                      footprint > 0 else { return nil }
                return footprint
            }
            memoryRefreshTask = task
        }

        let footprint = await task.value
        guard generation == memoryRefreshGeneration else { return false }
        memoryRefreshTask = nil
        guard let footprint else { return false }
        if memoryFootprint != footprint { memoryFootprint = footprint }
        return true
    }

    /// phys_footprint 正常每 5 秒查询；首次失败时每秒重试，直到拿到第一个数值。
    private func startMemoryPolling() {
        stopMemoryPolling()
        memoryTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let succeeded = await self.refreshMemory()
                guard !Task.isCancelled else { return }
                let interval: UInt64 = succeeded ? 5_000_000_000 : 1_000_000_000
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    private func stopMemoryPolling() {
        memoryTask?.cancel()
        memoryTask = nil
        memoryRefreshGeneration &+= 1
        memoryRefreshTask?.cancel()
        memoryRefreshTask = nil
        if memoryFootprint != nil { memoryFootprint = nil }
    }

    private func pushSample(up: Int64, down: Int64, uptime: Int64) {
        var updatedSamples = runtime.samples
        updatedSamples.append(TrafficSample(id: sampleIndex, up: up, down: down))
        sampleIndex += 1
        if updatedSamples.count > maxSamples {
            updatedSamples.removeFirst(updatedSamples.count - maxSamples)
        }
        runtime = RuntimeSnapshot(up: up, down: down, uptime: uptime, samples: updatedSamples)
    }

    private func setReachable(_ value: Bool) {
        if reachable != value { reachable = value }
    }
}
