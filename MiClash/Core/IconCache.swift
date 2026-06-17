import UIKit
import CryptoKit

/// 策略组图标缓存：内存(NSCache) + 磁盘(Caches/icons)。
/// 首次下载后落盘，之后(含 App 重启)直接命中，不再重复联网。
final class IconCache {
    static let shared = IconCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let io = DispatchQueue(label: "com.miclash.iconcache", qos: .utility)

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("icons", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 取缓存图（先内存后磁盘）。命中磁盘时顺带回填内存。
    func cached(_ url: URL) -> UIImage? {
        let key = Self.key(url)
        if let img = memory.object(forKey: key as NSString) { return img }
        let file = dir.appendingPathComponent(key)
        guard let data = try? Data(contentsOf: file), let img = UIImage(data: data) else { return nil }
        memory.setObject(img, forKey: key as NSString)
        return img
    }

    /// 下载并缓存（已缓存则直接返回）。
    func load(_ url: URL) async -> UIImage? {
        if let hit = cached(url) { return hit }
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = UIImage(data: data) else { return nil }
        let key = Self.key(url)
        memory.setObject(img, forKey: key as NSString)
        let file = dir.appendingPathComponent(key)
        io.async { try? data.write(to: file, options: .atomic) }
        return img
    }

    /// 用 URL 的 SHA256 当文件名——跨启动稳定（Swift 的 hashValue 每次运行变，不能用）。
    private static func key(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
