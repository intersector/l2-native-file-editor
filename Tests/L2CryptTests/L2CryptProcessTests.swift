import Foundation
import L2Crypt
import Testing

/// Tests that run against fake `/bin/sh` helpers, so they need neither the real helper nor fixtures.
@Suite struct L2CryptProcessTests {
    @Test func largeOutputOnBothStreamsDoesNotDeadlock() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            // 1 MiB on each stream: far beyond a pipe buffer.
            let fake = try TestFiles.script("""
                head -c 1048576 /dev/zero | tr '\\0' o
                head -c 1048576 /dev/zero | tr '\\0' e >&2
                exit 3
                """, in: directory)
            let input = directory.appendingPathComponent("in.dat")
            try Data([1, 2, 3]).write(to: input)
            do {
                try await L2Crypt(helper: fake).encode(
                    input: input, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
                Issue.record("expected the fake helper to fail")
            } catch let L2CryptError.helperFailed(exitCode, stdout, stderr, _) {
                #expect(exitCode == 3)
                #expect(stdout.utf8.count == 1_048_576)
                #expect(stderr.utf8.count == 1_048_576)
            }
        }
    }

    @Test func encodeAlwaysPassesProtocolAndEndsOptions() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let fake = try TestFiles.script("echo 'Invalid protocol' >&2; exit 1", in: directory)
            let input = directory.appendingPathComponent("dec-itemname-e.dat")
            let output = directory.appendingPathComponent("out.dat")
            try Data([0]).write(to: input)
            let error = await #expect(throws: L2CryptError.self) {
                try await L2Crypt(helper: fake).encode(input: input, output: output, protocol: .v413)
            }
            #expect(error == .helperFailed(
                exitCode: 1, stdout: "", stderr: "Invalid protocol\n",
                arguments: ["-c", "encode", "-p", "413", "-o", output.path, "--", input.path]))
            #expect(error?.description.contains("Invalid protocol") == true)
        }
    }

    @Test func protocol121PassesOriginalFileNameAndLegacyFlag() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let fake = try TestFiles.script("exit 1", in: directory)
            let input = directory.appendingPathComponent("temp-copy.dat")
            let output = directory.appendingPathComponent("out.dat")
            try Data([0]).write(to: input)
            let codec = L2Crypt(helper: fake)

            let decodeError = await #expect(throws: L2CryptError.self) {
                _ = try await codec.decode(
                    input: input, output: output, protocol: .v121, legacyKeys: true,
                    originalFileName: "l2.ini")
            }
            #expect(decodeError == .helperFailed(
                exitCode: 1, stdout: "", stderr: "",
                arguments: ["-c", "decode", "-p", "121", "-o", output.path, "-l", "-f", "l2.ini", "--", input.path]))

            // -f is only meaningful for 121 and is omitted otherwise.
            let encodeError = await #expect(throws: L2CryptError.self) {
                try await codec.encode(input: input, output: output, protocol: .v413, originalFileName: "l2.ini")
            }
            #expect(encodeError == .helperFailed(
                exitCode: 1, stdout: "", stderr: "",
                arguments: ["-c", "encode", "-p", "413", "-o", output.path, "--", input.path]))
        }
    }

    @Test func decodeWithoutProtocolRejectsUnknownHeader() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let fake = try TestFiles.script("exit 0", in: directory)
            let input = directory.appendingPathComponent("plain.ini")
            try Data("not an encrypted file at all".utf8).write(to: input)
            await #expect(throws: L2CryptError.unrecognizedHeader(file: input.path)) {
                _ = try await L2Crypt(helper: fake).decode(
                    input: input, output: directory.appendingPathComponent("out.ini"))
            }
        }
    }

    @Test func missingHelperFailsToLaunch() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let missing = directory.appendingPathComponent("no-such-helper")
            let input = directory.appendingPathComponent("in.dat")
            try Data([0]).write(to: input)
            let error = await #expect(throws: L2CryptError.self) {
                try await L2Crypt(helper: missing).encode(
                    input: input, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
            }
            guard case .launchFailed(let executable, _) = error else {
                Issue.record("expected launchFailed, got \(String(describing: error))")
                return
            }
            #expect(executable == missing.path)
        }
    }

    @Test func locatePrefersOverrides() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let fake = try TestFiles.script("exit 0", in: directory, name: "l2encdec")
            let missing = directory.appendingPathComponent("missing/l2encdec")
            #expect(try L2CryptHelper.locate(overrides: [missing, fake]) == fake)
        }
    }
}
