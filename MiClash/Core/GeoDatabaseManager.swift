import Foundation
import Mihomo

private let geoMaximumAssetBytes: Int64 = 64 * 1_024 * 1_024

struct GeoInstalledInfo: Sendable {
    let updatedAt: Date
    let size: Int64
}

private struct InstalledInfoConfiguration: Sendable {
    let home: URL
    let configYAML: String
    let settingsJSON: String
    let geoEnabled: Bool
    let geodataMode: Bool
}

private struct ResolvedGeoURLs: Decodable, Sendable {
    let geoip: String
    let mmdb: String
    let geosite: String
    let asn: String
    let geoRequired: Bool
    let asnRequired: Bool
}

/// 主 App 负责下载 GEO / ASN 数据到 App Group；NE 只读取已安装文件。
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
        guard settings.geoAutoUpdate else { return }
        let configYAML = SubscriptionStore.shared.activeYAML ?? ""
        let resolved = resolveURLs(
            configYAML: configYAML,
            settingsJSON: settings.asJSON(
                applyOverrides: SubscriptionStore.shared.activeOverridesEnabled))
        guard settings.geoEnabled && (resolved.geoRequired || resolved.asnRequired) else { return }
        guard AppGroup.containerURL != nil else { return }
        do {
            try await updateIfNeeded(force: false, configYAML: configYAML)
        } catch {
            publish(error: error)
        }
    }

    /// 连接前确保当前配置需要的 GEO / ASN 文件存在，并按自动更新间隔刷新。
    func prepareForConnection(configYAML: String?) async throws {
        let yaml = configYAML ?? ""
        let settings = SettingsStore.shared
        let resolved = resolveURLs(
            configYAML: yaml,
            settingsJSON: settings.asJSON(
                applyOverrides: SubscriptionStore.shared.activeOverridesEnabled))
        guard settings.geoEnabled && (resolved.geoRequired || resolved.asnRequired) else { return }
        // 重签环境可能拿不到 App Group。连接层会把有效 geo 设置降级为关闭，
        // 由配置合并层剔除依赖数据库的规则，不能因此阻断整个 VPN。
        guard AppGroup.containerURL != nil else { return }
        try await updateIfNeeded(force: false, configYAML: yaml)
        do {
            try await validateInstalledAssets(configYAML: yaml)
        } catch {
            try await updateIfNeeded(force: true, configYAML: yaml)
            try await validateInstalledAssets(configYAML: yaml)
        }
    }

    /// 设置页手动更新全部启用的 GEO / ASN 数据，不依赖当前配置是否恰好引用它们。
    func updateManually() async throws {
        do {
            guard SettingsStore.shared.geoEnabled else { throw GeoError.geoDisabled }
            try await updateIfNeeded(force: true,
                                     includeAll: true,
                                     configYAML: SubscriptionStore.shared.activeYAML ?? "")
        } catch {
            publish(error: error)
            throw error
        }
    }

    /// 设置页只在相关状态变化时调用一次；配置解析和文件读取均放到后台。
    func installedInfo(geodataMode: Bool) async -> GeoInstalledInfo? {
        guard let home = AppGroup.containerURL else { return nil }
        let settings = SettingsStore.shared
        let config = InstalledInfoConfiguration(
            home: home,
            configYAML: SubscriptionStore.shared.activeYAML ?? "",
            settingsJSON: settings.asJSON(
                applyOverrides: SubscriptionStore.shared.activeOverridesEnabled),
            geoEnabled: settings.geoEnabled,
            geodataMode: geodataMode)
        return await Task.detached(priority: .utility) {
            Self.readInstalledInfo(config)
        }.value
    }

    private func updateIfNeeded(force: Bool,
                                includeAll: Bool = false,
                                configYAML: String) async throws {
        if let activeUpdate {
            try await activeUpdate.value
            return
        }

        let settings = SettingsStore.shared
        guard let home = AppGroup.containerURL else { throw GeoError.appGroupUnavailable }
        let geodataMode = settings.geodataMode
        let autoUpdate = settings.geoAutoUpdate
        let updateInterval = settings.geoUpdateInterval
        let assets = requiredAssets(configYAML: configYAML,
                                    geodataMode: geodataMode,
                                    includeAll: includeAll)
        guard !assets.isEmpty else { return }
        let config = DownloadConfiguration(
            home: home,
            assets: assets
        )
        let filesMissing = !assetsAvailable(home: config.home, assets: config.assets)
        let stale = assetsAreStale(home: config.home,
                                   assets: config.assets,
                                   intervalHours: updateInterval)
        guard force || filesMissing || (autoUpdate && stale) else { return }

        let task: Task<Void, Error> = Task.detached(priority: .utility) {
            try await Self.downloadAndInstall(config)
        }
        activeUpdate = task
        isUpdating = true
        statusText = "正在下载并校验 \(assets.count) 个数据库…"
        statusIsError = false
        defer {
            activeUpdate = nil
            isUpdating = false
        }

        do {
            try await task.value
            revision += 1
            statusIsError = false
            statusText = "GEO / ASN 数据已更新"
        } catch {
            publish(error: error)
            throw error
        }
    }

    private func validateInstalledAssets(configYAML: String) async throws {
        guard let home = AppGroup.containerURL else { throw GeoError.appGroupUnavailable }
        let assets = requiredAssets(configYAML: configYAML,
                                    geodataMode: SettingsStore.shared.geodataMode)
        try await Task.detached(priority: .utility) {
            let sizes = Dictionary(uniqueKeysWithValues: assets.map { asset in
                let path = home.appendingPathComponent(asset.fileName).path
                let attributes = try? FileManager.default.attributesOfItem(atPath: path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                return (asset.fileName, size)
            })
            let missing = assets.map(\.fileName).filter { (sizes[$0] ?? 0) < 1_024 }
            if !missing.isEmpty { throw GeoError.missingFiles(missing) }
            for asset in assets {
                if (sizes[asset.fileName] ?? 0) > geoMaximumAssetBytes {
                    throw GeoError.tooLarge(asset.fileName, geoMaximumAssetBytes)
                }
                let path = home.appendingPathComponent(asset.fileName).path
                var validationError: NSError?
                guard MihomoValidateGeoDatabase(path, asset.kind, &validationError) else {
                    throw GeoError.validationFailed(asset.fileName,
                                                    validationError?.localizedDescription)
                }
            }
        }.value
    }

    private func assetsAvailable(home: URL, assets: [AssetDownload]) -> Bool {
        assets.allSatisfy {
            let size = fileSize(home.appendingPathComponent($0.fileName)) ?? 0
            return size >= 1_024 && size <= geoMaximumAssetBytes
        }
    }

    private func assetsAreStale(home: URL, assets: [AssetDownload], intervalHours: Int) -> Bool {
        let dates = assets.compactMap { modificationDate(home.appendingPathComponent($0.fileName)) }
        guard dates.count == assets.count, let oldest = dates.min() else { return true }
        return Date().timeIntervalSince(oldest) >= TimeInterval(max(intervalHours, 1) * 3_600)
    }

    private func requiredAssets(configYAML: String,
                                geodataMode: Bool,
                                includeAll: Bool = false) -> [AssetDownload] {
        let settings = SettingsStore.shared
        let resolved = resolveURLs(
            configYAML: configYAML,
            settingsJSON: settings.asJSON(
                applyOverrides: SubscriptionStore.shared.activeOverridesEnabled))
        var assets: [AssetDownload] = []
        if settings.geoEnabled && (includeAll || resolved.geoRequired) {
            assets.append(AssetDownload(
                label: geodataMode ? "GeoIP.dat" : "geoip.metadb",
                url: geodataMode ? resolved.geoip : resolved.mmdb,
                fileName: geodataMode ? "GeoIP.dat" : "geoip.metadb",
                kind: geodataMode ? "geoip" : "mmdb"))
            assets.append(AssetDownload(label: "GeoSite.dat", url: resolved.geosite,
                                        fileName: "GeoSite.dat", kind: "geosite"))
        }
        if settings.geoEnabled && (includeAll || resolved.asnRequired) {
            assets.append(AssetDownload(label: "ASN.mmdb", url: resolved.asn,
                                        fileName: "ASN.mmdb", kind: "asn"))
        }
        return assets
    }

    private func resolveURLs(configYAML: String, settingsJSON: String) -> ResolvedGeoURLs {
        let json = MihomoResolveGeoDownloadURLs(configYAML, settingsJSON)
        guard let data = json.data(using: .utf8),
              let resolved = try? JSONDecoder().decode(ResolvedGeoURLs.self, from: data) else {
            return ResolvedGeoURLs(
                geoip: SettingsStore.defaultGeoIPDatURL,
                mmdb: SettingsStore.defaultGeoMMDBURL,
                geosite: SettingsStore.defaultGeoSiteURL,
                asn: SettingsStore.defaultASNURL,
                geoRequired: false,
                asnRequired: false)
        }
        return resolved
    }

    private func modificationDate(_ url: URL) -> Date? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return attributes?[.modificationDate] as? Date
    }

    private func fileSize(_ url: URL) -> Int64? {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.int64Value
    }

    nonisolated private static func readInstalledInfo(
        _ config: InstalledInfoConfiguration
    ) -> GeoInstalledInfo? {
        let resolvedJSON = MihomoResolveGeoDownloadURLs(config.configYAML,
                                                        config.settingsJSON)
        let resolved = resolvedJSON.data(using: .utf8).flatMap {
            try? JSONDecoder().decode(ResolvedGeoURLs.self, from: $0)
        }
        guard config.geoEnabled else { return nil }
        var names = [config.geodataMode ? "GeoIP.dat" : "geoip.metadb", "GeoSite.dat"]
        if resolved?.asnRequired == true
            || FileManager.default.fileExists(
                atPath: config.home.appendingPathComponent("ASN.mmdb").path) {
            names.append("ASN.mmdb")
        }
        guard !names.isEmpty else { return nil }

        var oldestDate: Date?
        var totalSize: Int64 = 0
        for name in names {
            let url = config.home.appendingPathComponent(name)
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
                  let date = attributes[.modificationDate] as? Date,
                  let size = (attributes[.size] as? NSNumber)?.int64Value else {
                return nil
            }
            oldestDate = min(oldestDate ?? date, date)
            totalSize += size
        }
        guard let oldestDate else { return nil }
        return GeoInstalledInfo(updatedAt: oldestDate, size: totalSize)
    }

    private func publish(error: Error) {
        statusIsError = true
        statusText = error.localizedDescription
    }

    private struct DownloadConfiguration: Sendable {
        let home: URL
        let assets: [AssetDownload]
    }

    private struct AssetDownload: Sendable {
        let label: String
        let url: String
        let fileName: String
        let kind: String
    }

    private struct StagedAsset: Sendable {
        let url: URL
        let fileName: String
    }

    nonisolated private static func downloadAndInstall(_ config: DownloadConfiguration) async throws {
        try FileManager.default.createDirectory(at: config.home,
                                                withIntermediateDirectories: true)

        var staged: [StagedAsset] = []
        do {
            for asset in config.assets {
                staged.append(try await stageAsset(label: asset.label,
                                                   urlString: asset.url,
                                                   fileName: asset.fileName,
                                                   kind: asset.kind,
                                                   home: config.home))
            }
            for asset in staged {
                try install(asset, home: config.home)
            }
        } catch {
            for asset in staged {
                try? FileManager.default.removeItem(at: asset.url)
            }
            throw error
        }
    }

    nonisolated private static func stageAsset(label: String,
                                              urlString: String,
                                              fileName: String,
                                              kind: String,
                                              home: URL) async throws -> StagedAsset {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            throw GeoError.invalidURL(label)
        }

        var request = URLRequest(url: url)
        request.setValue("clash-meta", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60

        let download: BoundedHTTPDownload
        do {
            download = try await downloadWithRetry(request: request)
        } catch let error as BoundedHTTPDownloadError {
            switch error {
            case .httpStatus(let code):
                throw GeoError.httpStatus(label, code)
            case .tooLarge:
                throw GeoError.tooLarge(label, geoMaximumAssetBytes)
            default:
                throw GeoError.downloadFailed(label, error.localizedDescription)
            }
        } catch {
            throw GeoError.downloadFailed(label, error.localizedDescription)
        }
        defer { try? FileManager.default.removeItem(at: download.fileURL) }

        let temporaryURL = download.fileURL
        let http = download.response
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

        var validationError: NSError?
        guard MihomoValidateGeoDatabase(temporaryURL.path, kind, &validationError) else {
            throw GeoError.validationFailed(label, validationError?.localizedDescription)
        }

        let stagedURL = home.appendingPathComponent(".\(fileName).\(UUID().uuidString).download")
        try FileManager.default.copyItem(at: temporaryURL, to: stagedURL)
        return StagedAsset(url: stagedURL, fileName: fileName)
    }

    nonisolated private static func downloadWithRetry(
        request: URLRequest
    ) async throws -> BoundedHTTPDownload {
        var lastError: Error?
        for attempt in 1...3 {
            do {
                return try await BoundedHTTPDownloader.download(
                    for: request,
                    maxBytes: geoMaximumAssetBytes,
                    resourceTimeout: 180)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                guard attempt < 3, isRetryableDownloadError(error) else { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
        throw lastError ?? BoundedHTTPDownloadError.invalidResponse
    }

    nonisolated private static func isRetryableDownloadError(_ error: Error) -> Bool {
        if let error = error as? BoundedHTTPDownloadError {
            switch error {
            case .invalidResponse:
                return true
            case .httpStatus(let code):
                return code == 408 || code == 425 || code == 429 || (500...599).contains(code)
            case .invalidURL, .tooLarge:
                return false
            }
        }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled, .badURL, .unsupportedURL, .fileDoesNotExist,
                 .noPermissionsToReadFile, .dataLengthExceedsMaximum:
                return false
            default:
                return true
            }
        }
        return true
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

private enum GeoError: LocalizedError, Sendable {
    case appGroupUnavailable
    case geoDisabled
    case invalidURL(String)
    case httpStatus(String, Int)
    case downloadFailed(String, String)
    case tooLarge(String, Int64)
    case tooSmall(String)
    case invalidContent(String)
    case validationFailed(String, String?)
    case missingFiles([String])

    var errorDescription: String? {
        switch self {
        case .appGroupUnavailable:
            return "共享目录不可用，主 App 无法把 GEO / ASN 数据交给隧道扩展"
        case .geoDisabled:
            return "请先启用 GEO 规则"
        case .invalidURL(let name):
            return "\(name) 下载地址无效"
        case .httpStatus(let name, let code):
            return "\(name) 下载失败：HTTP \(code)"
        case .downloadFailed(let name, let reason):
            return "\(name) 下载失败：\(reason)"
        case .tooLarge(let name, let limit):
            return "\(name) 超过 \(limit / 1_048_576) MB 下载上限"
        case .tooSmall(let name):
            return "\(name) 下载内容过小"
        case .invalidContent(let name):
            return "\(name) 下载结果不是有效的数据库文件"
        case .validationFailed(let name, let reason):
            return "\(name) 数据库校验失败" + (reason.map { "：\($0)" } ?? "")
        case .missingFiles(let names):
            return "缺少 GEO / ASN 数据文件：\(names.joined(separator: "、"))"
        }
    }
}
