import Foundation

/// 字节数/速率的人类可读格式化。
enum ByteFormat {
    static func size(_ bytes: Int64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = Double(bytes); var i = 0
        while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
        return i == 0 ? "\(Int(v)) \(units[i])" : String(format: "%.2f %@", v, units[i])
    }
    static func rate(_ bytesPerSec: Int64) -> String { size(bytesPerSec) + "/s" }
}
