import Foundation

struct BoundedHTTPDownload: @unchecked Sendable {
    let fileURL: URL
    let response: HTTPURLResponse
}

enum BoundedHTTPDownloadError: LocalizedError, Sendable {
    case invalidURL
    case invalidResponse
    case httpStatus(Int)
    case tooLarge(limit: Int64)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "下载地址必须是有效的 HTTP/HTTPS 链接"
        case .invalidResponse:
            return "服务器返回了无法识别的响应"
        case .httpStatus(let code):
            return "HTTP \(code)"
        case .tooLarge(let limit):
            return "下载内容超过 \(limit / 1_048_576) MB 上限"
        }
    }
}

/// 把响应体写入临时文件，并在传输过程中强制执行体积上限。
/// 每次请求使用独立的 ephemeral session，便于取消且不会把订阅/数据库写入 URLCache。
final class BoundedHTTPDownloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private let maxBytes: Int64
    private let resourceTimeout: TimeInterval
    private let lock = NSLock()

    private var continuation: CheckedContinuation<BoundedHTTPDownload, Error>?
    private var session: URLSession?
    private var task: URLSessionDownloadTask?
    private var downloaded: BoundedHTTPDownload?
    private var recordedError: Error?
    private var cancelled = false
    private var finished = false

    private init(maxBytes: Int64, resourceTimeout: TimeInterval) {
        self.maxBytes = maxBytes
        self.resourceTimeout = resourceTimeout
    }

    static func download(for request: URLRequest,
                         maxBytes: Int64,
                         resourceTimeout: TimeInterval) async throws -> BoundedHTTPDownload {
        guard maxBytes > 0 else { throw BoundedHTTPDownloadError.tooLarge(limit: 0) }
        let worker = BoundedHTTPDownloader(maxBytes: maxBytes,
                                           resourceTimeout: resourceTimeout)
        return try await withTaskCancellationHandler {
            try await worker.start(request)
        } onCancel: {
            worker.cancel()
        }
    }

    private func start(_ request: URLRequest) async throws -> BoundedHTTPDownload {
        guard Self.isAllowedHTTPURL(request.url) else {
            throw BoundedHTTPDownloadError.invalidURL
        }

        return try await withCheckedThrowingContinuation { continuation in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = resourceTimeout

            let session = URLSession(configuration: configuration,
                                     delegate: self,
                                     delegateQueue: nil)
            let task = session.downloadTask(with: request)

            lock.lock()
            if cancelled {
                lock.unlock()
                session.invalidateAndCancel()
                continuation.resume(throwing: CancellationError())
                return
            }
            self.continuation = continuation
            self.session = session
            self.task = task
            lock.unlock()
            task.resume()
        }
    }

    private func cancel() {
        lock.lock()
        cancelled = true
        if recordedError == nil { recordedError = CancellationError() }
        let task = task
        lock.unlock()
        task?.cancel()
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.isAllowedHTTPURL(request.url) ? request : nil)
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        if totalBytesWritten > maxBytes
            || (totalBytesExpectedToWrite > maxBytes && totalBytesExpectedToWrite > 0) {
            record(error: BoundedHTTPDownloadError.tooLarge(limit: maxBytes))
            downloadTask.cancel()
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        lock.lock()
        let alreadyFailed = recordedError != nil
        lock.unlock()
        guard !alreadyFailed else { return }

        do {
            guard let response = downloadTask.response as? HTTPURLResponse,
                  Self.isAllowedHTTPURL(response.url) else {
                throw BoundedHTTPDownloadError.invalidResponse
            }
            guard (200..<300).contains(response.statusCode) else {
                throw BoundedHTTPDownloadError.httpStatus(response.statusCode)
            }

            let attributes = try FileManager.default.attributesOfItem(atPath: location.path)
            let byteCount = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            guard byteCount <= maxBytes else {
                throw BoundedHTTPDownloadError.tooLarge(limit: maxBytes)
            }

            let managedURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("cora-download-\(UUID().uuidString)")
            try FileManager.default.moveItem(at: location, to: managedURL)

            lock.lock()
            downloaded = BoundedHTTPDownload(fileURL: managedURL, response: response)
            lock.unlock()
        } catch {
            record(error: error)
        }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true

        let completedDownload = downloaded
        let result: Result<BoundedHTTPDownload, Error>
        if let recordedError {
            result = .failure(recordedError)
        } else if let error {
            result = .failure(error)
        } else if let completedDownload {
            result = .success(completedDownload)
        } else {
            result = .failure(BoundedHTTPDownloadError.invalidResponse)
        }

        let continuation = continuation
        let session = self.session
        let abandonedFile: URL?
        if case .failure = result {
            abandonedFile = completedDownload?.fileURL
        } else {
            abandonedFile = nil
        }
        self.continuation = nil
        self.session = nil
        self.task = nil
        self.downloaded = nil
        lock.unlock()

        if let abandonedFile { try? FileManager.default.removeItem(at: abandonedFile) }
        session?.finishTasksAndInvalidate()
        continuation?.resume(with: result)
    }

    private func record(error: Error) {
        lock.lock()
        if recordedError == nil { recordedError = error }
        lock.unlock()
    }

    private static func isAllowedHTTPURL(_ url: URL?) -> Bool {
        guard let url,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host?.isEmpty == false else { return false }
        return true
    }
}
