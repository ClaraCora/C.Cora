import Foundation

/// 消费 mihomo external-controller 的流式接口（/traffic、/logs）。
/// 所有状态都隔离在 MainActor；URLSession 回调只把结果投递回来。
@MainActor
final class MihomoStream: NSObject {

    var onObject: (([String: Any]) -> Void)?
    var onClose: ((Error?) -> Void)?

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var reconnectTask: Task<Void, Never>?
    private var pingTask: Task<Void, Never>?
    private var path = ""
    private var query: [URLQueryItem] = []
    private var active = false
    private var generation = 0
    private var reconnectAttempt = 0

    func start(path: String, query: [URLQueryItem] = []) {
        stop()
        self.path = path
        self.query = query
        active = true
        reconnectAttempt = 0
        connect()
    }

    func stop() {
        active = false
        generation &+= 1
        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }

    private func connect() {
        guard active else { return }
        generation &+= 1
        let currentGeneration = generation

        reconnectTask?.cancel()
        reconnectTask = nil
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        session?.invalidateAndCancel()

        let endpoint = MihomoAPI.configuration()
        var components = URLComponents()
        components.scheme = "ws"
        components.host = "127.0.0.1"
        components.port = endpoint.port
        components.path = "/" + path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !query.isEmpty { components.queryItems = query }
        guard let url = components.url else {
            scheduleReconnect(generation: currentGeneration)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        let newSession = URLSession(configuration: configuration)
        let request: URLRequest = {
            var value = URLRequest(url: url)
            if !endpoint.secret.isEmpty {
                value.setValue("Bearer \(endpoint.secret)",
                               forHTTPHeaderField: "Authorization")
            }
            return value
        }()
        let socket = newSession.webSocketTask(with: request)
        session = newSession
        task = socket
        socket.resume()
        receive(socket, generation: currentGeneration)
        startPing(socket, generation: currentGeneration)
    }

    private func receive(_ socket: URLSessionWebSocketTask, generation: Int) {
        socket.receive { [weak self, weak socket] result in
            guard let socket else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      self.active,
                      generation == self.generation,
                      self.task === socket else { return }
                switch result {
                case .success(let message):
                    self.reconnectAttempt = 0
                    switch message {
                    case .string(let text): self.emit(Data(text.utf8))
                    case .data(let data): self.emit(data)
                    @unknown default: break
                    }
                    self.receive(socket, generation: generation)
                case .failure(let error):
                    self.handleSocketFailure(error, socket: socket,
                                             generation: generation)
                }
            }
        }
    }

    private func startPing(_ socket: URLSessionWebSocketTask, generation: Int) {
        pingTask = Task { @MainActor [weak self, weak socket] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 20_000_000_000)
                } catch {
                    return
                }
                guard let self, let socket,
                      self.active,
                      generation == self.generation,
                      self.task === socket else { return }
                socket.sendPing { [weak self, weak socket] error in
                    guard let error, let socket else { return }
                    Task { @MainActor [weak self] in
                        self?.handleSocketFailure(error, socket: socket,
                                                  generation: generation)
                    }
                }
            }
        }
    }

    private func handleSocketFailure(_ error: Error,
                                     socket: URLSessionWebSocketTask,
                                     generation: Int) {
        guard active, generation == self.generation, task === socket else { return }
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
        onClose?(error)
        scheduleReconnect(generation: generation)
    }

    private func scheduleReconnect(generation: Int) {
        guard active, reconnectTask == nil else { return }
        let exponent = min(reconnectAttempt, 5)
        let delaySeconds = min(15, 1 << exponent)
        reconnectAttempt += 1
        reconnectTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(delaySeconds) * 1_000_000_000)
            } catch {
                return
            }
            guard let self,
                  self.active,
                  generation == self.generation else { return }
            self.reconnectTask = nil
            self.connect()
        }
    }

    private func emit(_ data: Data) {
        if let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            onObject?(object)
        }
    }
}
