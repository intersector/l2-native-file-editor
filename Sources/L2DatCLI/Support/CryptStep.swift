import Foundation
import L2Crypt

/// Runs `L2Crypt` after checking what the helper cannot: the input exists, the output goes to an
/// existing, writable directory and is not the input, and an encode input is not already encrypted.
/// The helper truncates its `-o` file before writing, so it only ever writes a temporary sibling
/// of the output that this process created exclusively (`.l2dat-*.tmp`, mode 0600), which
/// replaces the output atomically once the helper succeeded.
enum CryptStep {
    static func decode(
        _ codec: L2Crypt, input: URL, output: URL, protocol requested: L2Protocol?,
        legacyKeys: Bool = false, originalFileName: String? = nil
    ) async throws -> L2Protocol {
        try FileIO.requireInputFile(input)
        try FileIO.requireDistinct(input: input, output: output)
        try FileIO.requireOutputDirectory(output)
        return try await staged(output) { temporary in
            try await codec.decode(
                input: input, output: temporary, protocol: requested, legacyKeys: legacyKeys,
                originalFileName: originalFileName)
        }
    }

    static func encode(
        _ codec: L2Crypt, input: URL, output: URL, protocol target: L2Protocol, originalFileName: String?
    ) async throws {
        try FileIO.requireInputFile(input)
        try FileIO.requireDistinct(input: input, output: output)
        try FileIO.requireOutputDirectory(output)
        if let existing = HeaderSniffer.protocolOf(try head(of: input)) {
            throw CLIError("\(input.path) is already encrypted (\(existing.header) header); decode it first")
        }
        // The protocol-121 key derives from the input's name (or -f), never from the output's.
        try await staged(output) { temporary in
            try await codec.encode(input: input, output: temporary, protocol: target, originalFileName: originalFileName)
        }
    }

    /// Runs `body` with a new, exclusively created temporary sibling of `output`, then moves it
    /// onto `output` (keeping its mode); the temporary file is removed on any failure.
    private static func staged<Value>(_ output: URL, _ body: (URL) async throws -> Value) async throws -> Value {
        try await OutputStage.run { stage in
            let temporary = try stage.reserve(for: output)
            return try await body(temporary)
        }
    }

    private static func head(of url: URL) throws -> [UInt8] {
        do {
            let handle = try FileHandle(forReadingFrom: url)
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: HeaderSniffer.headerLength) ?? Data())
        } catch {
            throw CLIError("cannot read \(url.path): \(error.localizedDescription)")
        }
    }
}
