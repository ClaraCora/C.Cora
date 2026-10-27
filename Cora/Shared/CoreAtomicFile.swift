import Foundation

/// Stage and validate on the destination volume before replacing an asset.
/// Failed validation never changes the installed file or the download source.
enum CoreAtomicFile {
    static func stage(_ source: URL, fileName: String, home: URL,
                      validate: (URL) throws -> Void) throws -> URL {
        let staged = home.appendingPathComponent(".\(fileName).\(UUID().uuidString).download")
        do {
            try FileManager.default.copyItem(at: source, to: staged)
            try validate(staged)
            return staged
        } catch {
            try? FileManager.default.removeItem(at: staged)
            throw error
        }
    }

    static func install(_ staged: URL, at target: URL) throws {
        let fileManager = FileManager.default
        // Both paths must be on the same volume for atomic replacement.
        guard staged.deletingLastPathComponent().standardizedFileURL == target.deletingLastPathComponent().standardizedFileURL else {
            throw NSError(domain: "CoraCore", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "临时文件必须与目标文件位于同一目录"])
        }
        if fileManager.fileExists(atPath: target.path) {
            _ = try fileManager.replaceItemAt(target, withItemAt: staged)
        } else {
            try fileManager.moveItem(at: staged, to: target)
        }
    }
}
