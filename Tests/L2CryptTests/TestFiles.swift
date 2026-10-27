import Foundation
import L2Crypt
import TestSupport

/// Temporary directory and fixture lookups shared by the L2Crypt tests.
enum TestFiles {
    static let encryptedItemName = RepoPaths.fixtures.appendingPathComponent("enc/itemname-e.dat")
    static let decryptedItemName = RepoPaths.fixtures.appendingPathComponent("dec/dec-itemname-e.dat")

    /// The real helper (`$L2ENCDEC`, `build/bin`, upstream build), if one is present.
    static var helper: URL? { try? L2CryptHelper.locate() }

    /// True when both the helper and the itemname-e fixture pair are present.
    static var helperAndFixturesAvailable: Bool {
        helper != nil
            && FileManager.default.fileExists(atPath: encryptedItemName.path)
            && FileManager.default.fileExists(atPath: decryptedItemName.path)
    }

    /// Runs `body` with a fresh temporary directory that is removed afterwards.
    static func withTemporaryDirectory<T>(_ body: (URL) async throws -> T) async throws -> T {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("L2CryptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        return try await body(directory)
    }

    /// Writes an executable `/bin/sh` script to `directory` and returns its URL.
    static func script(_ body: String, in directory: URL, name: String = "fake-l2encdec") throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data("#!/bin/sh\n\(body)\n".utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }
}
