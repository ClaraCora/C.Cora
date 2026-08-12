import Foundation
import Mihomo  // gomobile 由 MobileCore 包生成的 mihomo 内核绑定框架

/// 对 gomobile 自动生成的 C/ObjC 绑定做一层 Swift 封装，隔离底层符号，
/// 让上层（CoreStateManager 等）只依赖干净的 Swift API，不直接碰 gomobile 符号。
///
/// Phase 1 只暴露版本号；Phase 2 起在此追加 setup/start/stop 等内核控制。
enum MihomoCore {

    /// mihomo 内核版本字符串。
    /// 能正常返回即证明内核已编进 App 并可从 Swift 调用。
    /// 对应 Go 侧 `func Version() string` → gomobile 生成 `MihomoVersion()`。
    static func version() -> String {
        MihomoVersion()
    }

    static func proxyProviderManifest(configYAML: String) -> Data {
        Data(MihomoProxyProviderManifest(configYAML).utf8)
    }

    static func validateProxyProviderPayload(_ payload: String) -> String? {
        var validationError: NSError?
        guard MihomoValidateProxyProviderPayload(payload, &validationError) else {
            return validationError?.localizedDescription ?? "Provider 内容无效"
        }
        return nil
    }

    static func offlineProxySnapshot(configYAML: String,
                                     providerPayloadsJSON: String,
                                     selectionsJSON: String) -> Data {
        Data(MihomoOfflineProxySnapshot(configYAML, providerPayloadsJSON, selectionsJSON).utf8)
    }

}
