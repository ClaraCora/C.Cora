import Foundation

/// 消费 mihomo external-controller 的 chunked 流式接口（/traffic、/logs）。
///
/// 用 URLSessionDataDelegate 的 didReceive 增量接收，按换行切分逐条解析 JSON——
/// 比 URLSession.bytes.lines 对「永不结束的 chunked 流」更可靠（后者常因缓冲不吐数据）。
/// 回调在后台 delegate 队列触发，调用方自行切回主线程更新 UI。
final class MihomoStream: NSObject, URLSessionDataDelegate, @unchecked Sendable {

    /// 每解析出一行 JSON 对象回调一次。
    var onObject: (([String: Any]) -> Void)?
    /// 连接结束/出错回调。
    var onClose: ((Error?) -> Void)?

    private var session: URLSession?
    private let lock = NSLock()
    private var buffer = Data()

    func start(path: String) {
        stop()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 3600   // 每秒有数据，长超时避免被掐
        cfg.timeoutIntervalForResource = 86400
        cfg.waitsForConnectivity = false
        let s = URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
        lock.lock(); buffer.removeAll(); lock.unlock()
        session = s
        s.dataTask(with: MihomoAPI.base.appendingPathComponent(path)).resume()
    }

    func stop() {
        session?.invalidateAndCancel()
        session = nil
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        var parsed: [[String: Any]] = []
        lock.lock()
        buffer.append(data)
        while let nl = buffer.firstIndex(of: 0x0A) {  // '\n'，mihomo json.Encoder 每条带换行
            let lineData = Data(buffer[buffer.startIndex..<nl])
            buffer.removeSubrange(buffer.startIndex...nl)
            if !lineData.isEmpty,
               let obj = (try? JSONSerialization.jsonObject(with: lineData)) as? [String: Any] {
                parsed.append(obj)
            }
        }
        lock.unlock()
        for obj in parsed { onObject?(obj) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        onClose?(error)
    }
}
