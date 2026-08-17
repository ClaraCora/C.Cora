import Foundation

/// App 与 Network Extension 之间共享的当前 VPN 会话延迟快照。
///
/// 文件只保存节点名称和整数延迟，体积很小。会话 ID 由 NE 在每次
/// startTunnel 时重新生成，因此 App 重启可以恢复同一会话，重连则自动丢弃旧结果。
struct ProxyDelaySnapshot: Codable {
    static let currentVersion = 1

    let version: Int
    let sessionID: String
    let delays: [String: Int]
}

enum ProxyDelayStore {
    private static let fileName = "proxy-delays.json"
    private static let lock = NSLock()

    private static var fileURL: URL? {
        if let container = AppGroup.containerURL {
            return container.appendingPathComponent(fileName)
        }

        // 保留无 App Group 签名的降级能力。正式签名与 TrollStore 都会
        // 走共享容器，NE 才能在 stopTunnel 时同步清理。
        return FileManager.default.urls(for: .applicationSupportDirectory,
                                        in: .userDomainMask).first?
            .appendingPathComponent("Cora", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// 新 VPN 会话开始时调用，原子地写入空快照。
    @discardableResult
    static func beginSession() -> String {
        let sessionID = UUID().uuidString
        write(ProxyDelaySnapshot(version: ProxyDelaySnapshot.currentVersion,
                                 sessionID: sessionID,
                                 delays: [:]))
        return sessionID
    }

    static func load() -> ProxyDelaySnapshot? {
        lock.lock()
        defer { lock.unlock() }
        return readLocked()
    }

    /// 只允许当前会话写入，避免旧的异步测速在新会话中复活。
    static func save(_ delays: [String: Int], sessionID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let current = readLocked(),
              current.version == ProxyDelaySnapshot.currentVersion,
              current.sessionID == sessionID else { return }
        writeLocked(ProxyDelaySnapshot(version: current.version,
                                       sessionID: sessionID,
                                       delays: delays))
    }

    /// VPN 断开时调用。删除快照而不是写入空数据，避免下次启动误判为旧会话。
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func write(_ snapshot: ProxyDelaySnapshot) {
        lock.lock()
        defer { lock.unlock() }
        writeLocked(snapshot)
    }

    private static func readLocked() -> ProxyDelaySnapshot? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let snapshot = try? JSONDecoder().decode(ProxyDelaySnapshot.self,
                                                       from: data),
              snapshot.version == ProxyDelaySnapshot.currentVersion,
              !snapshot.sessionID.isEmpty else { return nil }
        return snapshot
    }

    private static func writeLocked(_ snapshot: ProxyDelaySnapshot) {
        guard let url = fileURL else { return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: url, options: .atomic)
        } catch {
            // 延迟显示失败不应影响 VPN 主流程。
        }
    }
}
