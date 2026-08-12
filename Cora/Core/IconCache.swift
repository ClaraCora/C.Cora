import UIKit
import CryptoKit
import ImageIO

/// 策略组图标缓存：内存(NSCache) + 磁盘(Caches/icons)。
/// 首次下载后落盘，之后(含 App 重启)直接命中，不再重复联网。
final class IconCache {
    static let shared = IconCache()

    private let memory = NSCache<NSString, UIImage>()
    private let dir: URL
    private let io = DispatchQueue(label: "com.cora.iconcache", qos: .utility)

    private static let maximumDownloadBytes: Int64 = 2 * 1_024 * 1_024
    private static let maximumDiskBytes = 32 * 1_024 * 1_024
    private static let targetDiskBytes = 24 * 1_024 * 1_024
    private static let maximumDiskFiles = 512
    private static let maximumSourceDimension = 4_096
    private static let maximumSourcePixels = 16_777_216

    private init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        dir = caches.appendingPathComponent("icons", isDirectory: true)
        memory.totalCostLimit = 8 * 1024 * 1024
        memory.countLimit = 256
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        io.async { [dir] in Self.pruneDiskCache(in: dir) }
    }

    /// 内存命中立即返回；磁盘读取与图片解码都在 utility 队列完成。
    func load(_ url: URL) async -> UIImage? {
        let key = Self.key(url)
        if let img = memory.object(forKey: key as NSString) { return img }

        if let diskImage = await readDiskImage(key: key) {
            storeInMemory(diskImage, key: key)
            return diskImage
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        guard let download = try? await BoundedHTTPDownloader.download(
            for: request,
            maxBytes: Self.maximumDownloadBytes,
            resourceTimeout: 20) else { return nil }
        defer { try? FileManager.default.removeItem(at: download.fileURL) }

        guard let data = try? Data(contentsOf: download.fileURL),
              let img = await decode(data) else { return nil }
        storeInMemory(img, key: key)
        let file = dir.appendingPathComponent(key)
        io.async { [dir] in
            try? data.write(to: file, options: .atomic)
            Self.pruneDiskCache(in: dir)
        }
        return img
    }

    private func readDiskImage(key: String) async -> UIImage? {
        let file = dir.appendingPathComponent(key)
        return await withCheckedContinuation { continuation in
            io.async {
                guard let data = try? Data(contentsOf: file),
                      let image = Self.thumbnail(from: data) else {
                    try? FileManager.default.removeItem(at: file)
                    continuation.resume(returning: nil)
                    return
                }
                try? FileManager.default.setAttributes([.modificationDate: Date()],
                                                       ofItemAtPath: file.path)
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
    /// ImageIO 只读取尺寸并解码第一帧；最终缩放仍通过预乘 alpha 的绘图上下文，
    /// 避免透明边缘出现杂色，同时不加载 GIF/APNG 的全部动画帧。
    private static func thumbnail(from data: Data) -> UIImage? {
        guard let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil)
                as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumSourceDimension,
              height <= maximumSourceDimension,
              width <= maximumSourcePixels / height,
              let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else { return nil }

        let orientationValue = (properties[kCGImagePropertyOrientation] as? NSNumber)?.intValue ?? 1
        let source = UIImage(cgImage: cgImage,
                             scale: 1,
                             orientation: imageOrientation(orientationValue))
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

    private static func imageOrientation(_ value: Int) -> UIImage.Orientation {
        switch value {
        case 2: return .upMirrored
        case 3: return .down
        case 4: return .downMirrored
        case 5: return .leftMirrored
        case 6: return .right
        case 7: return .rightMirrored
        case 8: return .left
        default: return .up
        }
    }

    private static func pruneDiskCache(in directory: URL) {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey,
                                         .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]) else { return }

        var entries: [(url: URL, size: Int, date: Date)] = []
        var totalBytes = 0
        for url in files {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            let size = values.fileSize ?? 0
            totalBytes += size
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        guard totalBytes > maximumDiskBytes || entries.count > maximumDiskFiles else { return }

        entries.sort { $0.date < $1.date }
        var remainingFiles = entries.count
        for entry in entries {
            guard totalBytes > targetDiskBytes || remainingFiles > maximumDiskFiles else { break }
            do {
                try FileManager.default.removeItem(at: entry.url)
                totalBytes -= entry.size
                remainingFiles -= 1
            } catch {
                continue
            }
        }
    }

    /// 用 URL 的 SHA256 当文件名——跨启动稳定（Swift 的 hashValue 每次运行变，不能用）。
    private static func key(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
