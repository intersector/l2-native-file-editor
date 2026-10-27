import Foundation
import L2Crypt
import Testing

/// Round trips through the real `l2encdec` helper on the High Five fixtures.
/// Skipped when the helper or the (gitignored) fixtures are absent.
@Suite(.enabled(if: TestFiles.helperAndFixturesAvailable, "needs the l2encdec helper and fixtures/high5"))
struct L2CryptHelperRoundTripTests {
    let codec: L2Crypt

    init() throws {
        codec = try L2Crypt()
    }

    @Test func decodeMatchesFixture() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("dec-itemname-e.dat")
            let detected = try await codec.decode(input: TestFiles.encryptedItemName, output: output)
            #expect(detected == .v413)
            #expect(try Data(contentsOf: output) == Data(contentsOf: TestFiles.decryptedItemName))
        }
    }

    @Test func encodeThenDecodeRestoresPlaintext() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let encrypted = directory.appendingPathComponent("itemname-e.dat")
            let decrypted = directory.appendingPathComponent("dec-itemname-e.dat")
            try await codec.encode(input: TestFiles.decryptedItemName, output: encrypted, protocol: .v413)

            let head = try [UInt8](Data(contentsOf: encrypted).prefix(HeaderSniffer.headerLength))
            #expect(HeaderSniffer.protocolOf(head) == .v413)

            #expect(try await codec.decode(input: encrypted, output: decrypted) == .v413)
            #expect(try Data(contentsOf: decrypted) == Data(contentsOf: TestFiles.decryptedItemName))
        }
    }

    @Test func wrongProtocolThrowsWithHelperMessage() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            // A protocol-111 (XOR) file decoded as 413 (RSA + zlib) cannot decompress. The header is
            // blanked so the explicit protocol is trusted instead of rejected as a mismatch.
            let xorEncrypted = directory.appendingPathComponent("itemname-e.dat")
            try await codec.encode(input: TestFiles.decryptedItemName, output: xorEncrypted, protocol: .v111)
            var bytes = try Data(contentsOf: xorEncrypted)
            bytes.replaceSubrange(0..<HeaderSniffer.headerLength, with: Data(count: HeaderSniffer.headerLength))
            try bytes.write(to: xorEncrypted)
            let error = await #expect(throws: L2CryptError.self) {
                _ = try await codec.decode(
                    input: xorEncrypted, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
            }
            guard case let .helperFailed(exitCode, _, stderr, arguments) = error else {
                Issue.record("expected helperFailed, got \(String(describing: error))")
                return
            }
            #expect(exitCode != 0)
            #expect(!stderr.isEmpty)
            #expect(arguments.contains("413"))
        }
    }

    @Test func requestedProtocolContradictingHeaderThrows() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let output = directory.appendingPathComponent("out.dat")
            for wrong in [L2Protocol.v111, .v120, .v121, .v211, .v212] {
                let error = await #expect(throws: L2CryptError.self) {
                    _ = try await codec.decode(input: TestFiles.encryptedItemName, output: output, protocol: wrong)
                }
                #expect(error == .protocolMismatch(
                    file: TestFiles.encryptedItemName.path, header: .v413, requested: wrong))
            }
            #expect(!FileManager.default.fileExists(atPath: output.path))
            // 411-414 are one format: a different member of the family still decodes.
            let sibling = try await codec.decode(
                input: TestFiles.encryptedItemName, output: output, protocol: .v412)
            #expect(sibling == .v412)
        }
    }

    @Test func legacyKeysOnModernFileThrows() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let error = await #expect(throws: L2CryptError.self) {
                _ = try await codec.decode(
                    input: TestFiles.encryptedItemName, output: directory.appendingPathComponent("out.dat"),
                    legacyKeys: true)
            }
            guard case let .helperFailed(_, _, stderr, _) = error else {
                Issue.record("expected helperFailed, got \(String(describing: error))")
                return
            }
            #expect(stderr.contains("Failed to"))
        }
    }
}
