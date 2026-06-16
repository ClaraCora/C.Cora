import Foundation

/// 消费 mihomo external-controller 的流式接口（/traffic、/logs）——WebSocket。
///
/// mihomo 流式主通道是 WebSocket（普通 GET 的 chunked 在 iOS URLSession 收不到）。
/// 实测连上后可能收到一帧就断，故加 **自动重连 + 定时 ping 保活**，保证持续有数据。
/// 回调在后台触发，调用方自行切回主线程更新 UI。
final class MihomoStream: NSObject, @unchecked Sendable {

    var onObject: (([String: Any]) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var path = ""
    private var active = false
    private var generation = 0   // 每次 connect 自增，旧的接收/ping/重连循环据此失效

    func start(path: String) {
        stop()
        self.path = path
        active = true
        connect()
    }

    func stop() {
        active = false
        generation &+= 1
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        generation &+= 1
        let gen = generation

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        let s = URLSession(configuration: cfg)
        session = s

        var comps = URLComponents(url: MihomoAPI.base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        let t = s.webSocketTask(with: comps.url!)
        task = t
        t.resume()

        receive(gen)
    }

    private func receive(_ gen: Int) {
        task?.receive { [weak self] result in
            guard let self, self.active, gen == self.generation else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text): self.emit(Data(text.utf8))
                case .data(let data): self.emit(data)
                @unknown default: break
                }
                self.receive(gen)
            case .failure(let error):
                self.onClose?(error)
                self.scheduleReconnect()
            }
        }
    }

    /// 断流后快速重连（页面仍可见、未 stop 时）；间隙短到几乎无感。
    private func scheduleReconnect() {
        guard active else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, self.active else { return }
            self.connect()
        }
    }

    private func emit(_ data: Data) {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            onObject?(obj)
        }
    }
}
