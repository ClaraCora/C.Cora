import Foundation
import MeowCore

/// The only shared Swift surface that owns Rust strings. No engine is started
/// by an offline request in the main application.
enum CoraNativeCore {
    static func request(_ command: String, _ fields: [String: Any] = [:]) -> Data {
        var object = fields
        object["v"] = 1
        object["cmd"] = command
        guard let data = try? JSONSerialization.data(withJSONObject: object) else {
            return error("内核请求编码失败")
        }
        return data.withUnsafeBytes { bytes in
            guard let pointer = cora_core_request(bytes.bindMemory(to: UInt8.self).baseAddress, UInt(data.count)) else {
                return error("Rust 内核没有返回响应")
            }
            defer { meow_string_free(pointer) }
            return Data(String(cString: pointer).utf8)
        }
    }

    static func object(_ command: String, _ fields: [String: Any] = [:]) throws -> [String: Any] {
        let data = request(command, fields)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw failure("内核响应格式无效")
        }
        if let message = object["error"] as? String { throw failure(message) }
        return object
    }

    static func dictionary(_ string: String) -> [String: Any] {
        ((try? JSONSerialization.jsonObject(with: Data(string.utf8))) as? [String: Any]) ?? [:]
    }

    static func error(_ message: String, code: String = "unsupported") -> Data {
        encode(["ok": false, "error": message, "code": code])
    }

    static func encode(_ object: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "CoraCore", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }

    static var lastError: String {
        guard let message = meow_core_last_error() else { return "meow-rs 操作失败" }
        return String(cString: message)
    }
}
