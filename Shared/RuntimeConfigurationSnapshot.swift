import Foundation

struct RuntimeConfigurationSnapshot: Equatable {
    let configYAML: String
    let settingsJSON: String
}

/// A small manifest commits the YAML/settings pair atomically. Failed starts
/// never replace the last successful pair. Separate files avoid encoding a
/// second complete copy of a large subscription inside a JSON string in NE.
enum RuntimeConfigurationSnapshotStorage {
    private struct Manifest: Codable { let generation: UUID }
    private static let writeLock = NSLock()

    static var appDirectory: URL {
        AppGroup.containerURL ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    private static func location(in directory: URL) -> URL {
        directory.appendingPathComponent("RuntimeConfiguration", isDirectory: true)
    }

    private static func generation(in directory: URL) -> UUID? {
        guard let data = try? Data(contentsOf: location(in: directory).appendingPathComponent("current.json")) else { return nil }
        return (try? JSONDecoder().decode(Manifest.self, from: data))?.generation
    }

    static func settings(in directory: URL) -> String? {
        guard let id = generation(in: directory) else { return nil }
        return try? String(contentsOf: location(in: directory).appendingPathComponent("\(id.uuidString).json"), encoding: .utf8)
    }

    static func load(in directory: URL) -> RuntimeConfigurationSnapshot? {
        guard let id = generation(in: directory),
              let yaml = try? String(contentsOf: location(in: directory).appendingPathComponent("\(id.uuidString).yaml"), encoding: .utf8),
              let settings = try? String(contentsOf: location(in: directory).appendingPathComponent("\(id.uuidString).json"), encoding: .utf8) else { return nil }
        return RuntimeConfigurationSnapshot(configYAML: yaml, settingsJSON: settings)
    }

    static func save(_ snapshot: RuntimeConfigurationSnapshot, in directory: URL) throws {
        writeLock.lock()
        defer { writeLock.unlock() }
        let root = location(in: directory)
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        let previous = generation(in: directory)
        let id = UUID()
        let yamlURL = root.appendingPathComponent("\(id.uuidString).yaml")
        let settingsURL = root.appendingPathComponent("\(id.uuidString).json")
        do {
            try snapshot.configYAML.write(to: yamlURL, atomically: true, encoding: .utf8)
            try snapshot.settingsJSON.write(to: settingsURL, atomically: true, encoding: .utf8)
            for file in [yamlURL, settingsURL] {
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                #if os(iOS)
                try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
                #endif
            }
            let manifestURL = root.appendingPathComponent("current.json")
            try JSONEncoder().encode(Manifest(generation: id)).write(to: manifestURL, options: .atomic)
            try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)
        } catch {
            try? manager.removeItem(at: yamlURL)
            try? manager.removeItem(at: settingsURL)
            throw error
        }
        // Only remove our own UUID-named artifacts, after the new manifest is
        // durable. A partial write leaves the previous generation usable.
        for file in (try? manager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? [] {
            guard file.pathExtension == "yaml" || file.pathExtension == "json",
                  let old = UUID(uuidString: file.deletingPathExtension().lastPathComponent), old != id, old != previous else { continue }
            try? manager.removeItem(at: file)
        }
    }
}
