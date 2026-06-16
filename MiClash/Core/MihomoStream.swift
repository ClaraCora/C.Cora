import Foundation

/// 消费 mihomo external-controller 的流式接口（/traffic、/logs）。
///
/// mihomo 的流式主通道是 **WebSocket**（请求带 Upgrade 头即升级，逐帧推 JSON 文本）。
/// 普通 GET 的 chunked 回退在 iOS URLSession 上收不到数据，故这里用 URLSessionWebSocketTask。
/// 回调在后台触发，调用方自行切回主线程更新 UI。
final class MihomoStream: NSObject, @unchecked Sendable {

    /// 每收到一帧 JSON 对象回调一次。
    var onObject: (([String: Any]) -> Void)?
    /// 连接结束/出错回调。
    var onClose: ((Error?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var active = false

    /// path 如 "traffic" / "logs"。
    func start(path: String) {
        stop()
        active = true

        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600
        let s = URLSession(configuration: cfg)
        session = s

        // http://127.0.0.1:9090/<path> → ws://127.0.0.1:9090/<path>
        var comps = URLComponents(url: MihomoAPI.base.appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)!
        comps.scheme = "ws"
        let t = s.webSocketTask(with: comps.url!)
        task = t
        t.resume()
        receive()
    }

    func stop() {
        active = false
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func receive() {
        task?.receive { [weak self] result in
            guard let self, self.active else { return }
            switch result {
            case .success(let message):
                switch message {
                case .string(let text):
                    self.emit(Data(text.utf8))
                case .data(let data):
                    self.emit(data)
                @unknown default:
                    break
                }
                self.receive() // 继续收下一帧
            case .failure(let error):
                if self.active { self.onClose?(error) }
            }
        }
    }

    private func emit(_ data: Data) {
        if let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            onObject?(obj)
        }
    }
}
