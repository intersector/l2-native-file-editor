import Foundation

/// Finds the bundled `l2encdec` helper executable.
public enum L2CryptHelper {
    /// File name of the helper executable.
    public static let executableName = "l2encdec"

    /// Environment variable that points at a helper executable.
    public static let environmentVariable = "L2ENCDEC"

    /// Returns the first executable candidate, searched in this order:
    /// `overrides`, `$L2ENCDEC`, `<app bundle>/Contents/Helpers/l2encdec` (macOS),
    /// next to the running executable, and in DEBUG builds `<repo>/build/bin/l2encdec`
    /// and the upstream CMake build output.
    /// - Throws: `L2CryptError.helperNotFound` listing every searched path.
    public static func locate(overrides: [URL] = []) throws -> URL {
        let searched = candidates(overrides: overrides, environment: ProcessInfo.processInfo.environment)
        let fileManager = FileManager.default
        for candidate in searched {
            var isDirectory: ObjCBool = false
            if fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               fileManager.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        throw L2CryptError.helperNotFound(searched: searched.map(\.path))
    }

    static func candidates(overrides: [URL], environment: [String: String]) -> [URL] {
        var result = overrides
        if let path = environment[environmentVariable], !path.isEmpty {
            result.append(URL(fileURLWithPath: path))
        }
        #if os(macOS)
        result.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(executableName)"))
        #endif
        if let executable = Bundle.main.executableURL {
            result.append(executable.resolvingSymlinksInPath()
                .deletingLastPathComponent()
                .appendingPathComponent(executableName))
        }
        #if DEBUG
        // This file is <repo>/Sources/L2Crypt/L2CryptHelper.swift.
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        result.append(repo.appendingPathComponent("build/bin/\(executableName)"))
        result.append(repo.appendingPathComponent(
            "upstream/ritsuwastaken_open-l2encdec/build_unix/cli/\(executableName)"))
        #endif
        return result
    }
}
