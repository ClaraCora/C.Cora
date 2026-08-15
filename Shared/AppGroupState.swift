import Foundation

/// 跨进程共享的轻量状态：正式签名走 App Group UserDefaults，TrollStore 走共享文件。
/// 两种共享方式都不可用时读默认值、写静默失败，不影响 VPN 主流程。
enum AppGroupState {
    private static let lock = NSLock()

    private enum Key {
        static let vpnConnected = "vpnConnected"
        static let alwaysOnVPNEnabled = "alwaysOnVPNEnabled"
        static let vpnAutoConnectSuspended = "vpnAutoConnectSuspended"
    }

    /// VPN 是否处于连接（含连接中）状态。NE 启停时写入最准；主 App 状态变化时也同步。
    static var vpnConnected: Bool {
        get {
            switch AppGroup.containerKind {
            case .appGroup:
                return UserDefaults(suiteName: AppGroup.identifier)?
                    .bool(forKey: Key.vpnConnected) ?? false
            case .trollStore:
                lock.lock()
                defer { lock.unlock() }
                guard let url = AppGroup.containerURL?.appendingPathComponent("vpn-state"),
                      let value = try? String(contentsOf: url, encoding: .utf8) else {
                    return false
                }
                return value == "1"
            case .unavailable:
                return false
            }
        }
        set {
            switch AppGroup.containerKind {
            case .appGroup:
                UserDefaults(suiteName: AppGroup.identifier)?
                    .set(newValue, forKey: Key.vpnConnected)
            case .trollStore:
                lock.lock()
                defer { lock.unlock() }
                guard let url = AppGroup.containerURL?.appendingPathComponent("vpn-state") else {
                    return
                }
                try? (newValue ? "1" : "0").write(to: url,
                                                    atomically: true,
                                                    encoding: .utf8)
            case .unavailable:
                break
            }
        }
    }

    /// 主 App 与控制中心扩展共享的自动连接偏好。
    static var alwaysOnVPNEnabled: Bool {
        get { sharedBool(forKey: Key.alwaysOnVPNEnabled) }
        set { setSharedBool(newValue, forKey: Key.alwaysOnVPNEnabled) }
    }

    /// 用户从 Cora 控制中心按钮手动关闭后的暂停状态。
    static var vpnAutoConnectSuspended: Bool {
        get { sharedBool(forKey: Key.vpnAutoConnectSuspended) }
        set { setSharedBool(newValue, forKey: Key.vpnAutoConnectSuspended) }
    }

    private static func sharedBool(forKey key: String) -> Bool {
        switch AppGroup.containerKind {
        case .appGroup:
            return UserDefaults(suiteName: AppGroup.identifier)?.bool(forKey: key) ?? false
        case .trollStore:
            lock.lock()
            defer { lock.unlock() }
            guard let url = AppGroup.containerURL?.appendingPathComponent(key),
                  let value = try? String(contentsOf: url, encoding: .utf8) else {
                return false
            }
            return value == "1"
        case .unavailable:
            return false
        }
    }

    private static func setSharedBool(_ value: Bool, forKey key: String) {
        switch AppGroup.containerKind {
        case .appGroup:
            UserDefaults(suiteName: AppGroup.identifier)?.set(value, forKey: key)
        case .trollStore:
            lock.lock()
            defer { lock.unlock() }
            guard let url = AppGroup.containerURL?.appendingPathComponent(key) else { return }
            try? (value ? "1" : "0").write(to: url, atomically: true, encoding: .utf8)
        case .unavailable:
            break
        }
    }
}
