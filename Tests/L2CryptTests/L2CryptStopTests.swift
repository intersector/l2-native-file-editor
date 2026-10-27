#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import L2Crypt
import Testing

/// A helper that hangs, or leaves processes behind, is stopped with its whole process group: on timeout,
/// on cancellation, and when the helper exits while a child of it still holds the output pipes.
@Suite struct L2CryptStopTests {
    private static let clock = ContinuousClock()

    @Test func hangingShellHelperTimesOutAndItsGroupIsKilled() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let pidFile = directory.appendingPathComponent("group.pid")
            // sh waits for its child sleep, which holds the output pipes: killing sh alone would not end the run.
            let fake = try Self.warmScript("echo $$ > '\(pidFile.path)'\nsleep 60", in: directory)
            let input = try Self.input(in: directory)
            let start = Self.clock.now
            await #expect(throws: L2CryptError.timedOut(executable: fake.path, timeout: .seconds(1))) {
                try await L2Crypt(helper: fake, timeout: .seconds(1)).encode(
                    input: input, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
            }
            let elapsed = Self.clock.now - start
            #expect(elapsed < .seconds(2), "took \(elapsed)")
            let group = try Self.readPid(pidFile)
            #expect(await Self.groupIsGone(group), "pgrep -g \(group) still lists processes")
        }
    }

    @Test func cancellingTheTaskKillsTheGroup() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let pidFile = directory.appendingPathComponent("group.pid")
            let fake = try TestFiles.script("echo $$ > '\(pidFile.path)'\nsleep 60", in: directory)
            let input = try Self.input(in: directory)
            let output = directory.appendingPathComponent("out.dat")
            let task = Task {
                try await L2Crypt(helper: fake).encode(input: input, output: output, protocol: .v413)
            }
            try await Self.waitFor(pidFile)
            let start = Self.clock.now
            task.cancel()
            await #expect(throws: L2CryptError.cancelled(executable: fake.path)) { try await task.value }
            let elapsed = Self.clock.now - start
            #expect(elapsed < .seconds(2), "took \(elapsed)")
            let group = try Self.readPid(pidFile)
            #expect(await Self.groupIsGone(group), "pgrep -g \(group) still lists processes")
        }
    }

    @Test func taskCancelledBeforeTheRunNeverStartsTheHelper() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let marker = directory.appendingPathComponent("started")
            let fake = try TestFiles.script("touch '\(marker.path)'", in: directory)
            let input = try Self.input(in: directory)
            let output = directory.appendingPathComponent("out.dat")
            let task = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await L2Crypt(helper: fake).encode(input: input, output: output, protocol: .v413)
            }
            await #expect(throws: L2CryptError.cancelled(executable: fake.path)) { try await task.value }
            #expect(!FileManager.default.fileExists(atPath: marker.path))
        }
    }

    /// A process in another group (`set -m`) that keeps writing to the pipes is not killed with the group, so
    /// the run must not wait for EOF; closing the read ends makes its next write fail and it exits.
    @Test func processOutsideTheGroupHoldingThePipesCannotBlockAndLosesThem() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let holderFile = directory.appendingPathComponent("holder.pid")
            let fake = try Self.warmScript("""
                set -m
                ( while echo x && echo y >&2; do sleep 0.1; done ) &
                echo $! > '\(holderFile.path)'
                set +m
                sleep 60
                """, in: directory)
            let input = try Self.input(in: directory)
            let start = Self.clock.now
            await #expect(throws: L2CryptError.timedOut(executable: fake.path, timeout: .seconds(1))) {
                try await L2Crypt(helper: fake, timeout: .seconds(1)).encode(
                    input: input, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
            }
            let elapsed = Self.clock.now - start
            #expect(elapsed < .seconds(2), "took \(elapsed)")
            let holder = try Self.readPid(holderFile)
            defer { kill(holder, SIGKILL) }
            #expect(await Self.processIsGone(holder), "the writer outside the group still runs: a pipe stayed open")
        }
    }

    @Test func helperExitingWithAChildHoldingThePipesReturnsAtOnce() async throws {
        try await TestFiles.withTemporaryDirectory { directory in
            let pidFile = directory.appendingPathComponent("group.pid")
            let fake = try Self.warmScript(
                "echo $$ > '\(pidFile.path)'\nsleep 60 &\necho done\nexit 0", in: directory)
            let input = try Self.input(in: directory)
            let start = Self.clock.now
            try await L2Crypt(helper: fake, timeout: .seconds(30)).encode(
                input: input, output: directory.appendingPathComponent("out.dat"), protocol: .v413)
            let elapsed = Self.clock.now - start
            #expect(elapsed < .seconds(2), "took \(elapsed)")
            let group = try Self.readPid(pidFile)
            #expect(await Self.groupIsGone(group), "the helper's leftover child survived")
        }
    }

    // MARK: - Helpers

    /// A fake helper that has already run once (`--warm` exits at once): the first run of a new script is
    /// slowed by the system's executable scan, which would eat into a one-second time limit.
    private static func warmScript(_ body: String, in directory: URL) throws -> URL {
        let url = try TestFiles.script("[ \"$1\" = --warm ] && exit 0\n" + body, in: directory)
        let process = Process()
        process.executableURL = url
        process.arguments = ["--warm"]
        try process.run()
        process.waitUntilExit()
        return url
    }

    private static func input(in directory: URL) throws -> URL {
        let input = directory.appendingPathComponent("in.dat")
        try Data([0]).write(to: input)
        return input
    }

    private static func readPid(_ file: URL) throws -> pid_t {
        let text = try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        return try #require(pid_t(text))
    }

    private static func waitFor(_ file: URL) async throws {
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: file.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// True once `pgrep -g group` lists nothing (killed processes may take a moment to be reaped).
    private static func groupIsGone(_ group: pid_t) async -> Bool {
        for _ in 0..<40 {
            if (try? pgrep(["-g", String(group)])) == false { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private static func processIsGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<40 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    /// Runs `pgrep` and returns whether it matched any process.
    private static func pgrep(_ arguments: [String]) throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
