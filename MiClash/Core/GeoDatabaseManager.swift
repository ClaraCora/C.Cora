import Foundation
import Mihomo

/// 主 App 负责下载 GEO 数据到 App Group；NE 只读取已安装文件。
@MainActor
final class GeoDatabaseManager: ObservableObject {
    static let shared = GeoDatabaseManager()

    @Published private(set) var isUpdating = false
    @Published private(set) var statusText: String?
    @Published private(set) var statusIsError = false
    @Published private(set) var revision = 0

    private var activeUpdate: Task<Void, Error>?

    private init() {}

    /// App 启动时只执行用户开启的定时更新；缺文件会在连接前强制补齐。
    func updateOnLaunch() async {
        let settings = SettingsStore.shared
        guard settings.geoEnabled, settings.geoAutoUpdate else { return }
        do {
            try await updateIfNeeded(force: false)
        } catch {
            publish(error: error)
        }
    }

    /// 连接前确保当前模式所需的两个文件存在，并按自动更新间隔刷新。
    func prepareForConnection() async throws {
        guard SettingsStore.shared.geoEnabled else { return }
        try await updateIfNeeded(force: false)
        try validateInstalledAssets(geodataMode: SettingsStore.shared.geodataMode)
    }

    /// 设置页手动下载/更新当前模式的 GEOIP 数据与 GeoSite.dat。
    func updateManually() async throws {
        try await updateIfNeeded(force: true)
    }

    func lastUpdatedAt(geodataMode: Bool) -> Date? {
        guard let home = AppGroup.containerURL else { return nil }
        let names = [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        let dates = names.compactMap { modificationDate(home.appendingPathComponent($0)) }
        guard dates.count == names.count else { return nil }
        return dates.min()
    }

    func installedSize(geodataMode: Bool) -> Int64? {
        guard let home = AppGroup.containerURL else { return nil }
        let names = [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        let sizes = names.compactMap { fileSize(home.appendingPathComponent($0)) }
        guard sizes.count == names.count else { return nil }
        return sizes.reduce(0, +)
    }

    private func updateIfNeeded(force: Bool) async throws {
        if let activeUpdate {
            try await activeUpdate.value
            return
        }

        let settings = SettingsStore.shared
        guard let home = AppGroup.containerURL else { throw GeoError.appGroupUnavailable }
        let geodataMode = settings.geodataMode
        let autoUpdate = settings.geoAutoUpdate
        let updateInterval = settings.geoUpdateInterval
        let geoIPURL = geodataMode ? settings.geoIPDatURL : settings.geoMMDBURL
        let geoSiteURL = settings.geoSiteURL
        let config = DownloadConfiguration(
            home: home,
            geodataMode: geodataMode,
            geoIPURL: geoIPURL,
            geoIPFileName: geodataMode ? "GeoIP.dat" : "geoip.metadb",
            geoSiteURL: geoSiteURL
        )
        let filesMissing = !assetsAvailable(home: config.home, geodataMode: config.geodataMode)
        let stale = assetsAreStale(home: config.home,
                                   geodataMode: config.geodataMode,
                                   intervalHours: updateInterval)
        guard force || filesMissing || (autoUpdate && stale) else { return }

        let task: Task<Void, Error> = Task.detached(priority: .utility) {
            try await Self.downloadAndInstall(config)
        }
        activeUpdate = task
        isUpdating = true
        statusText = nil
        statusIsError = false
        defer {
            activeUpdate = nil
            isUpdating = false
        }

        do {
            try await task.value
            revision += 1
            statusIsError = false
            statusText = "GEO 数据已更新"
        } catch {
            publish(error: error)
            throw error
        }
    }

    private func validateInstalledAssets(geodataMode: Bool) throws {
        guard let home = AppGroup.containerURL else { throw GeoError.appGroupUnavailable }
        let names = [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        let missing = names.filter { (fileSize(home.appendingPathComponent($0)) ?? 0) < 1_024 }
        if !missing.isEmpty { throw GeoError.missingFiles(missing) }
    }

    private func assetsAvailable(home: URL, geodataMode: Bool) -> Bool {
        let names = [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        return names.allSatisfy { (fileSize(home.appendingPathComponent($0)) ?? 0) >= 1_024 }
    }

    private func assetsAreStale(home: URL, geodataMode: Bool, intervalHours: Int) -> Bool {
        let names = [geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        let dates = names.compactMap { modificationDate(home.appendingPathComponent($0)) }
        guard dates.count == names.count, let oldest = dates.min() else { return true }
        return Date().timeIntervalSince(oldest) >= TimeInterval(max(intervalHours, 1) * 3_600)
    }

    private func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    private func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    private func publish(error: Error) {
        statusIsError = true
        statusText = error.localizedDescription
    }

    private struct DownloadConfiguration: Sendable {
        let home: URL
        let geodataMode: Bool
        let geoIPURL: String
        let geoIPFileName: String
        let geoSiteURL: String
    }

    private struct StagedAsset: Sendable {
        let url: URL
        let fileName: String
    }

    nonisolated private static func downloadAndInstall(_ config: DownloadConfiguration) async throws {
        try FileManager.default.createDirectory(at: config.home,
                                                withIntermediateDirectories: true)
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.timeoutIntervalForRequest = 60
        sessionConfig.timeoutIntervalForResource = 180
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }

        let geoIP = try await stageAsset(label: config.geoIPFileName,
                                         urlString: config.geoIPURL,
                                         fileName: config.geoIPFileName,
                                         home: config.home,
                                         session: session)
        do {
            let geoSite = try await stageAsset(label: "GeoSite.dat",
                                               urlString: config.geoSiteURL,
                                               fileName: "GeoSite.dat",
                                               home: config.home,
                                               session: session)
            defer {
                try? FileManager.default.removeItem(at: geoIP.url)
                try? FileManager.default.removeItem(at: geoSite.url)
            }
            try install(geoIP, home: config.home)
            try install(geoSite, home: config.home)
        } catch {
            try? FileManager.default.removeItem(at: geoIP.url)
            throw error
        }
    }

    nonisolated private static func stageAsset(label: String,
                                              urlString: String,
                                              fileName: String,
                                              home: URL,
                                              session: URLSession) async throws -> StagedAsset {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw GeoError.invalidURL(label)
        }

        var request = URLRequest(url: url)
        request.setValue("clash-meta", forHTTPHeaderField: "User-Agent")
        let (temporaryURL, response) = try await session.download(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw GeoError.httpStatus(label, (response as? HTTPURLResponse)?.statusCode ?? -1)
        }
        if http.mimeType?.lowercased().contains("html") == true {
            throw GeoError.invalidContent(label)
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: temporaryURL.path)
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 1_024 else { throw GeoError.tooSmall(label) }

        let handle = try FileHandle(forReadingFrom: temporaryURL)
        let head = try handle.read(upToCount: 128) ?? Data()
        try? handle.close()
        let prefix = String(data: head, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if prefix?.hasPrefix("<!doctype html") == true || prefix?.hasPrefix("<html") == true {
            throw GeoError.invalidContent(label)
        }

        let kind = fileName == "geoip.metadb" ? "mmdb" :
            (fileName == "GeoIP.dat" ? "geoip" : "geosite")
        var validationError: NSError?
        guard MihomoValidateGeoDatabase(temporaryURL.path, kind, &validationError) else {
            throw GeoError.validationFailed(label, validationError?.localizedDescription)
        }

        let stagedURL = home.appendingPathComponent(".\(fileName).\(UUID().uuidString).download")
        try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
        return StagedAsset(url: stagedURL, fileName: fileName)
    }

    nonisolated private static func install(_ asset: StagedAsset, home: URL) throws {
        let fileManager = FileManager.default
        let target = home.appendingPathComponent(asset.fileName)
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: asset.url)
        } else {
            try fileManager.moveItem(at: asset.url, to: target)
        }
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
    }
}

private enum GeoError: LocalizedError {
    case appGroupUnavailable
    case invalidURL(String)
    case httpStatus(String, Int)
    case tooSmall(String)
    case invalidContent(String)
    case validationFailed(String, String?)
    case missingFiles([String])

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "App Group 不可用，主 App 无法把 GEO 数据共享给隧道扩展"
        case .invalidURL(let name):
            return "\(name) 下载地址无效"
        case .httpStatus(let name, let code):
            return "\(name) 下载失败：HTTP \(code)"
        case .tooSmall(let name):
            return "\(name) 下载内容过小"
        case .invalidContent(let name):
            return "\(name) 下载结果不是有效的数据库文件"
        case .validationFailed(let name, let reason):
            return "\(name) 数据库校验失败" + (reason.map { "：\($0)" } ?? "")
        case .missingFiles(let names):
            return "缺少 GEO 数据文件：\(names.joined(separator: "、"))"
        }
    }
}
