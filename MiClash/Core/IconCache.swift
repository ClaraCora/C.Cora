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
        memory.totalCostLimit = 8 * 1024 * 1024
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// 内存命中立即返回；磁盘读取与图片解码都在 utility 队列完成。
    func load(_ url: URL) async -> UIImage? {
        let key = Self.key(url)
        if let img = memory.object(forKey: key as NSString) { return img }

        if let diskImage = await readDiskImage(key: key) {
            storeInMemory(diskImage, key: key)
            return diskImage
        }

        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let img = await decode(data) else { return nil }
        storeInMemory(img, key: key)
        let file = dir.appendingPathComponent(key)
        io.async { try? data.write(to: file, options: .atomic) }
        return img
    }

    private func readDiskImage(key: String) async -> UIImage? {
        let file = dir.appendingPathComponent(key)
        return await withCheckedContinuation { continuation in
            io.async {
                guard let data = try? Data(contentsOf: file),
                      let image = Self.thumbnail(from: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func decode(_ data: Data) async -> UIImage? {
        await withCheckedContinuation { continuation in
            io.async {
                continuation.resume(returning: Self.thumbnail(from: data))
            }
        }
    }

    private func storeInMemory(_ image: UIImage, key: String) {
        let pixels = image.size.width * image.scale * image.size.height * image.scale
        memory.setObject(image, forKey: key as NSString, cost: Int(pixels * 4))
    }

    /// 组件固定为 32pt，按 96px 上限解码，避免大图标在滚动时占用完整纹理内存。
    /// 不用 ImageIO 缩略图：它重采样时不按 alpha 加权，透明像素残留的杂散 RGB
    /// 会渗进半透明边缘，透明图标周围出现一圈杂色。UIGraphicsImageRenderer 在
    /// 非 opaque（预乘 alpha）上下文中绘制，缩放是 alpha 加权的，边缘干净。
    private static func thumbnail(from data: Data) -> UIImage? {
        guard let source = UIImage(data: data) else { return nil }
        let maxPixel: CGFloat = 96
        let pixelSize = CGSize(width: source.size.width * source.scale,
                               height: source.size.height * source.scale)
        guard max(pixelSize.width, pixelSize.height) > maxPixel else { return source }

        let ratio = maxPixel / max(pixelSize.width, pixelSize.height)
        let target = CGSize(width: max(1, (pixelSize.width * ratio).rounded(.down)),
                            height: max(1, (pixelSize.height * ratio).rounded(.down)))
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = 1 // target 已是像素尺寸，scale 固定 1 避免二次放大
        return UIGraphicsImageRenderer(size: target, format: format).image { _ in
            source.draw(in: CGRect(origin: .zero, size: target))
        }
    }

    /// 用 URL 的 SHA256 当文件名——跨启动稳定（Swift 的 hashValue 每次运行变，不能用）。
    private static func key(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
