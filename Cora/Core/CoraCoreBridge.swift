import Foundation
import CryptoKit

/// Protocol-independent facade used by App models. Runtime control is sent to
/// the Network Extension; this process only parses immutable copies.
enum CoraCore {
    static func validateConfiguration(_ yaml: String, settingsJSON: String = "{}") -> String? {
        do {
            _ = try CoraNativeCore.object("validate", ["yaml": yaml,
                "settings": CoraNativeCore.dictionary(settingsJSON), "home": AppGroup.containerURL?.path ?? ""])
            return nil
        } catch { return error.localizedDescription }
    }

    static func convertSubscription(_ body: String) throws -> String {
        let result = try CoraNativeCore.object("convertSubscription", ["body": body])
        guard let yaml = result["yaml"] as? String else { throw CoraNativeCore.failure("订阅转换未返回 YAML") }
        return yaml
    }
    static func version() -> String {
        (try? CoraNativeCore.object("version")["version"] as? String) ?? "meow-rs (unavailable)"
    }

    static func proxyProviderManifest(configYAML: String) -> Data {
        remoteResourceManifest(configYAML: configYAML)
    }

    static func remoteResourceManifest(configYAML: String) -> Data {
        CoraNativeCore.request("manifest", ["yaml": configYAML])
    }

    static func validateProxyProviderPayload(_ payload: String) -> String? {
        do { _ = try CoraNativeCore.object("validateProvider", ["payload": payload]); return nil }
        catch { return error.localizedDescription }
    }

    static func validateGeoDatabase(_ path: String, kind: String) -> String? {
        do { _ = try CoraNativeCore.object("validateGeo", ["path": path, "kind": kind]); return nil }
        catch { return error.localizedDescription }
    }

    static func resolveGeoDownloadURLs(_ yaml: String, _ settings: String) -> String {
        String(decoding: CoraNativeCore.request("resolveGeo", ["yaml": yaml,
            "settings": CoraNativeCore.dictionary(settings)]), as: UTF8.self)
    }

    static func ruleProviderContent(name: String, maxBytes: Int = 1 << 20) -> Data {
        CoraNativeCore.error("规则内容需要连接 VPN 后通过内核读取")
    }

    static func scriptFetch(requestJSON: String) -> Data {
        CoraNativeCore.error("meow-rs 尚不支持 Cora 脚本请求；原脚本设置仍保留")
    }

    static func offlineProxySnapshot(configYAML: String, providerPayloadsJSON: String,
                                      selectionsJSON: String, profileID: String = "legacy") -> Data {
        CoraNativeCore.request("offlineSnapshot", ["yaml": configYAML,
            "cacheNamespace": SHA256.hash(data: Data((profileID + "\u{0}" + configYAML).utf8)).map { String(format: "%02x", $0) }.joined(),
            "providers": CoraNativeCore.dictionary(providerPayloadsJSON),
            "selections": CoraNativeCore.dictionary(selectionsJSON),
            "home": AppGroup.containerURL?.path ?? ""])
    }
}
