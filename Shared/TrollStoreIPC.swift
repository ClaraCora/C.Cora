import Foundation

/// Shared paths for the TrollStore-only file IPC transport.
///
/// The build marker is injected only into the TrollStore package. Regular
/// signed builds continue to use NetworkExtension's sendProviderMessage API.
enum TrollStoreIPC {
    static let buildMarkerKey = "MiClashTrollStoreBuild"

    static var isEnabled: Bool {
        (Bundle.main.object(forInfoDictionaryKey: buildMarkerKey) as? NSNumber)?.boolValue
            == true
    }

    static var directoryURL: URL? {
        guard isEnabled, let root = AppGroup.containerURL else { return nil }
        let directory = root.appendingPathComponent("ControlIPC", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory,
                                                    withIntermediateDirectories: true)
            return directory
        } catch {
            return nil
        }
    }

    static func requestURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).request")
    }

    static func processingURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).processing")
    }

    static func responseURL(for id: UUID) -> URL? {
        directoryURL?.appendingPathComponent("\(id.uuidString).response")
    }

    static func requestID(from url: URL) -> UUID? {
        guard url.pathExtension == "request" else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }

    static func removeAllFiles() {
        guard let directory = directoryURL,
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { return }
        for file in files where ["request", "processing", "response"]
            .contains(file.pathExtension) {
            try? FileManager.default.removeItem(at: file)
        }
    }
}
