import Foundation

/// A private scratch directory for intermediate files (decrypted or not yet encrypted data).
/// The directory and every file named through `file(_:)` are registered with `TemporaryFiles`,
/// so a SIGINT/SIGTERM/SIGHUP removes them too.
struct TemporaryDirectory: Sendable {
    let url: URL

    init() throws {
        TemporaryFiles.installHandlers()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("l2dat-\(UUID().uuidString)", isDirectory: true)
        TemporaryFiles.registerDirectory(url)
        do {
            try FileIO.createDirectory(url)
        } catch {
            TemporaryFiles.unregisterDirectory(url)
            throw error
        }
        self.url = url
    }

    func file(_ name: String) -> URL {
        let file = url.appendingPathComponent(name)
        TemporaryFiles.register(file)
        return file
    }

    func remove() {
        try? FileManager.default.removeItem(at: url)
        TemporaryFiles.unregisterDirectory(url)
    }
}
