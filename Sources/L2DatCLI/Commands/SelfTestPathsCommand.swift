#if DEBUG
import ArgumentParser
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// `l2dat _selftest-paths` (debug builds only): checks `FileIO.samePath`, the `--keep` directory
/// walk, temporary file creation and `OutputStage` commits against a scratch tree, including a
/// child `l2dat` that is killed by SIGTERM in the middle of a commit.
struct SelfTestPathsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_selftest-paths",
        abstract: "Check FileIO path handling and OutputStage against the file system (debug builds only).",
        shouldDisplay: false
    )

    @Option(help: "Directory to build the scratch tree in, e.g. on a case-sensitive volume (default: the temporary directory).")
    var directory: String?

    @Option(help: .hidden)
    var signalCommit: String?

    @Option(help: .hidden)
    var signalBeforeRename: Int = 0

    @Flag(help: .hidden)
    var probeHandlers = false

    func run() async throws {
        if probeHandlers {
            return try await probeSignalHandlers()
        }
        TemporaryFiles.installHandlers()
        if let signalCommit {
            return try commitAndRaise(in: URL(fileURLWithPath: signalCommit))
        }
        let manager = FileManager.default
        guard let executable = Bundle.main.executableURL else {
            throw CLIError("cannot locate the l2dat executable")
        }
        let parent = directory.map { URL(fileURLWithPath: $0) } ?? manager.temporaryDirectory
        let root = parent.appendingPathComponent("selftest-paths-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        func at(_ name: String) -> URL { URL(fileURLWithPath: root.path + "/" + name) }
        func relative(_ name: String) -> URL { URL(fileURLWithPath: name) }

        for name in ["a.txt", "b.txt"] { try Data().write(to: at(name)) }
        try manager.createDirectory(at: at("sub"), withIntermediateDirectories: false)
        try Data().write(to: at("sub/e.txt"))
        try manager.createDirectory(at: at("deep/inner"), withIntermediateDirectories: true)
        try manager.createSymbolicLink(atPath: at("link").path, withDestinationPath: "sub")
        try manager.createSymbolicLink(atPath: at("jump").path, withDestinationPath: "deep/inner")
        try manager.createSymbolicLink(atPath: at("loop").path, withDestinationPath: "loop")
        try manager.linkItem(at: at("a.txt"), to: at("hard.txt"))
        try manager.createDirectory(at: at("locked"), withIntermediateDirectories: false)
        try manager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: at("locked").path)
        // Runs before the removal above (defers run in reverse), so the tree can be deleted.
        defer { try? manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: at("locked").path) }
        // The volume's case rule, observed directly rather than through FileIO.
        let folds = manager.fileExists(atPath: at("A.TXT").path)
        // getcwd() returns the resolved path (/private/var/... on macOS), so relative URLs below
        // reach the scratch tree through a different spelling of its ancestors than `at(_:)`.
        guard manager.changeCurrentDirectoryPath(root.path) else {
            throw CLIError("cannot change directory to \(root.path)")
        }

        /// Asks the kernel: creates a file through `path` (relative to the scratch tree, after
        /// creating `directories`) and reports whether that made `other` appear.
        func kernelSame(_ path: String, _ other: String, creating directories: [String] = []) -> Bool {
            for name in directories { mkdir(root.path + "/" + name, 0o755) }
            defer { for name in directories.reversed() { rmdir(root.path + "/" + name) } }
            let descriptor = open(root.path + "/" + path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard descriptor >= 0 else { return false }
            close(descriptor)
            defer { unlink(root.path + "/" + path) }
            return access(root.path + "/" + other, F_OK) == 0
        }

        /// nil (samePath must throw) when the kernel fails `path` with anything but "does not exist".
        func kernelFailsClosed(_ path: String) -> Bool? {
            var info = stat()
            guard stat(root.path + "/" + path, &info) != 0, errno != ENOENT, errno != ENOTDIR else { return false }
            return nil
        }

        // Expected value: whether samePath returns true; nil means it must throw (fail closed).
        let cases: [(String, URL, URL, Bool?)] = [
            ("existing file, same spelling", at("a.txt"), at("a.txt"), true),
            ("existing file, different case", at("a.txt"), at("A.TXT"), folds),
            ("new file, same spelling", at("new.txt"), at("new.txt"), true),
            ("new file, different case", at("new.txt"), at("NEW.TXT"), folds),
            ("new file, existing parent in a different case", at("sub/n.txt"), at("SUB/n.txt"), folds),
            ("new file, parent and name in a different case", at("sub/n.txt"), at("SUB/N.TXT"), folds),
            ("existing file, existing parent in a different case", at("sub/e.txt"), at("SUB/e.txt"), folds),
            ("new file through a symlinked parent", at("link/n.txt"), at("sub/n.txt"), true),
            ("existing file through a symlinked parent", at("link/e.txt"), at("sub/e.txt"), true),
            ("'..' through an existing directory", at("sub/../new.txt"), at("new.txt"), true),
            ("'..' through a missing directory", at("missing/../new.txt"), at("new.txt"), true),
            ("'..' after a symlink is physical", at("jump/../n.txt"), at("deep/n.txt"), true),
            ("'..' after a symlink is not lexical", at("jump/../n.txt"), at("n.txt"), false),
            ("'..' out of a missing directory re-enters the file system",
                at("missing/../jump/../n.txt"), at("deep/n.txt"),
                kernelSame("missing/../jump/../n.txt", "deep/n.txt", creating: ["missing"])),
            ("'..' out of a missing directory is not lexical afterwards",
                at("missing/../jump/../n.txt"), at("n.txt"),
                kernelSame("missing/../jump/../n.txt", "n.txt", creating: ["missing"])),
            ("relative vs absolute, new file", relative("new.txt"), at("new.txt"), true),
            ("relative vs absolute, existing file", relative("a.txt"), at("a.txt"), true),
            ("relative vs absolute, different case", relative("NEW.TXT"), at("new.txt"), folds),
            ("relative '..' vs absolute", relative("sub/../NEW.TXT"), at("new.txt"), folds),
            ("relative '..' after a symlink is physical", relative("jump/../n.txt"), at("deep/n.txt"),
                kernelSame("jump/../n.txt", "deep/n.txt")),
            ("relative '..' after a symlink is not lexical", relative("jump/../n.txt"), at("n.txt"),
                kernelSame("jump/../n.txt", "n.txt")),
            ("relative and absolute '..' after a symlink agree", relative("jump/../n.txt"), at("jump/../n.txt"), true),
            ("relative '..' out of a missing directory re-enters the file system",
                relative("missing/../jump/../n.txt"), at("deep/n.txt"),
                kernelSame("missing/../jump/../n.txt", "deep/n.txt", creating: ["missing"])),
            ("FileIO.url keeps a relative '..' after a symlink physical", FileIO.url("jump/../n.txt"), at("deep/n.txt"),
                kernelSame("jump/../n.txt", "deep/n.txt")),
            ("hard link to the same file", at("hard.txt"), at("a.txt"), true),
            ("two different existing files", at("a.txt"), at("b.txt"), false),
            ("two different new files", at("new.txt"), at("other.txt"), false),
            ("same new name in different directories", at("sub/new.txt"), at("new.txt"), false),
            ("new file vs existing file", at("new.txt"), at("a.txt"), false),
            ("symlink loop fails closed", at("loop/x.txt"), at("a.txt"), kernelFailsClosed("loop/x.txt")),
            ("symlink loop vs a new file fails closed", at("loop/x.txt"), at("x.txt"), kernelFailsClosed("loop/x.txt")),
            ("unsearchable directory fails closed", at("locked/x.txt"), at("x.txt"), kernelFailsClosed("locked/x.txt")),
        ]
        var failures = 0
        for (name, lhs, rhs, expected) in cases {
            let forward = Result { try FileIO.samePath(lhs, rhs) }
            let backward = Result { try FileIO.samePath(rhs, lhs) }
            let passed = matches(forward, expected) && matches(backward, expected)
            if !passed { failures += 1 }
            print("\(passed ? "PASS" : "FAIL") \(name): \(show(forward)), \(show(backward)) (expected \(show(expected)))")
        }
        let checks = fileChecks(root: root, at: at) + signalChecks(root: root, executable: executable)
            + [handlerCheck(executable: executable)]
        for (name, check) in checks {
            let problem: String?
            do { problem = try check() } catch { problem = "throws (\(Console.describe(error)))" }
            if problem != nil { failures += 1 }
            print("\(problem == nil ? "PASS" : "FAIL") \(name)\(problem.map { ": \($0)" } ?? "")")
        }
        let total = cases.count + checks.count
        print("\(total - failures)/\(total) passed (case-insensitive volume: \(folds))")
        if failures > 0 {
            Console.error("\(failures) of \(total) path cases failed")
            throw ExitCode.failure
        }
    }

    /// Checks that return nil when they pass, else what went wrong. They run in `root`, after the
    /// samePath cases, and leave the tree as they found it.
    private func fileChecks(root: URL, at: @escaping (String) -> URL) -> [(String, () throws -> String?)] {
        let manager = FileManager.default
        func contents(_ name: String) -> String? {
            manager.contents(atPath: at(name).path).map { String(decoding: $0, as: UTF8.self) }
        }
        func mode(_ name: String) -> mode_t? {
            var info = stat()
            return stat(at(name).path, &info) == 0 ? info.st_mode & 0o777 : nil
        }
        func leftovers() throws -> [String] {
            try manager.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix(".l2dat-") }
        }
        /// --keep must be refused (with no directory created) or accepted, as `expectAccepted`.
        func keep(_ spelling: String, accepted expectAccepted: Bool) -> (String, () throws -> String?) {
            ("--keep \(spelling) is \(expectAccepted ? "accepted" : "refused")", {
                let before = try manager.contentsOfDirectory(atPath: root.path).sorted()
                let accepted: Bool
                do {
                    try FileIO.requireCreatableDirectory(FileIO.url(spelling))
                    accepted = true
                } catch {
                    accepted = false
                }
                if try manager.contentsOfDirectory(atPath: root.path).sorted() != before { return "created an entry" }
                return accepted == expectAccepted ? nil : (accepted ? "accepted" : "refused")
            })
        }
        /// Stages "new 1" for `first` (holding "old 1" with mode 0600 when `firstExists`) and
        /// "new 2" for `second`, which becomes a directory before the commit.
        func failedCommit(firstExists: Bool) -> String? {
            defer {
                unlink(at("out1.txt").path)
                rmdir(at("out2.txt").path)
            }
            if firstExists {
                guard manager.createFile(atPath: at("out1.txt").path, contents: Data("old 1".utf8),
                    attributes: [.posixPermissions: 0o600]) else { return "cannot create out1.txt" }
            }
            var stage = OutputStage()
            do {
                try stage.add(Array("new 1".utf8), for: at("out1.txt"))
                try stage.add(Array("new 2".utf8), for: at("out2.txt"))
            } catch {
                return "staging threw \(Console.describe(error))"
            }
            mkdir(at("out2.txt").path, 0o755)
            do {
                try stage.commit()
                return "commit onto a directory succeeded"
            } catch {
                let message = Console.describe(error)
                print("  (commit error: \(message))")
                guard message.contains(at("out1.txt").path), message.contains(at("out2.txt").path) else {
                    return "error does not name both outputs: \(message)"
                }
                if firstExists {
                    guard contents("out1.txt") == "old 1" else { return "out1.txt not restored: \(contents("out1.txt") ?? "missing")" }
                    guard mode("out1.txt") == 0o600 else { return "out1.txt mode changed" }
                } else if manager.fileExists(atPath: at("out1.txt").path) {
                    return "the new out1.txt was left in place"
                }
                let left = (try? leftovers()) ?? ["?"]
                return left.isEmpty ? nil : "temporary files left: \(left)"
            }
        }
        /// Both outputs exist ("old 1", "old 2"); the second rename fails because its temporary
        /// file vanished: the first output is restored, the second keeps its inode, no leftovers.
        func failedLinkedCommit() throws -> String? {
            defer {
                unlink(at("out1.txt").path)
                unlink(at("out2.txt").path)
            }
            try Data("old 1".utf8).write(to: at("out1.txt"))
            try Data("old 2".utf8).write(to: at("out2.txt"))
            let inode = self.inode(at("out2.txt"))
            var stage = OutputStage()
            try stage.add(Array("new 1".utf8), for: at("out1.txt"))
            try stage.add(Array("new 2".utf8), for: at("out2.txt"))
            do {
                try stage.commit { index, temporary in
                    if index == 1 { unlink(temporary.path) }
                }
                return "commit without its temporary file succeeded"
            } catch {
                print("  (commit error: \(Console.describe(error)))")
            }
            guard contents("out1.txt") == "old 1" else { return "out1.txt not restored: \(contents("out1.txt") ?? "missing")" }
            guard contents("out2.txt") == "old 2" else { return "out2.txt changed: \(contents("out2.txt") ?? "missing")" }
            guard self.inode(at("out2.txt")) == inode else { return "out2.txt was replaced (new inode)" }
            let left = try leftovers()
            return left.isEmpty ? nil : "temporary files left: \(left)"
        }
        return [
            keep("nope/..", accepted: false),
            keep("a.txt/..", accepted: false),
            keep("sub/nope/..", accepted: false),
            keep("sub/nope/../x", accepted: false),
            keep("a.txt", accepted: false),
            keep("sub", accepted: true),
            keep("sub/..", accepted: true),
            keep("nope/deeper", accepted: true),
            keep("sub/../nope", accepted: true),
            ("a planted file at the first temporary name is skipped and survives", {
                let planted = ".l2dat-0000000000000001.tmp"
                guard manager.createFile(atPath: at(planted).path, contents: Data("planted".utf8)) else {
                    return "cannot plant"
                }
                defer { unlink(at(planted).path) }
                var names = [planted, ".l2dat-0000000000000002.tmp"].makeIterator()
                let created = try FileIO.createTemporarySibling(of: at("out.txt"), names: { names.next()! })
                close(created.descriptor)
                _ = FileIO.remove(created.url)
                if created.url.lastPathComponent != ".l2dat-0000000000000002.tmp" {
                    return "created \(created.url.lastPathComponent)"
                }
                return contents(planted) == "planted" ? nil : "the planted file changed"
            }),
            ("only planted temporary names: refused, planted file survives", {
                let planted = ".l2dat-0000000000000003.tmp"
                guard manager.createFile(atPath: at(planted).path, contents: Data("planted".utf8)) else {
                    return "cannot plant"
                }
                defer { unlink(at(planted).path) }
                do {
                    let created = try FileIO.createTemporarySibling(of: at("out.txt"), names: { planted })
                    close(created.descriptor)
                    return "created \(created.url.lastPathComponent)"
                } catch {
                    return contents(planted) == "planted" ? nil : "the planted file changed"
                }
            }),
            ("a 255-byte output name commits", {
                let name = String(repeating: "n", count: 251) + ".txt"
                var stage = OutputStage()
                try stage.add(Array("long".utf8), for: at(name))
                try stage.commit()
                defer { unlink(at(name).path) }
                return contents(name) == "long" ? nil : "content is \(contents(name) ?? "missing")"
            }),
            ("second rename fails: existing first output restored, error names both", {
                failedCommit(firstExists: true)
            }),
            ("second rename fails: new first output removed, error names both", {
                failedCommit(firstExists: false)
            }),
            ("a replaced output keeps mode 0600, a new one gets 0666 & ~umask", {
                defer {
                    unlink(at("kept.txt").path)
                    unlink(at("fresh.txt").path)
                }
                guard manager.createFile(atPath: at("kept.txt").path, contents: Data("old".utf8),
                    attributes: [.posixPermissions: 0o600]) else { return "cannot create kept.txt" }
                var stage = OutputStage()
                try stage.add(Array("new".utf8), for: at("kept.txt"))
                try stage.add(Array("fresh".utf8), for: at("fresh.txt"))
                try stage.commit()
                let mask = umask(0)
                umask(mask)
                guard contents("kept.txt") == "new", contents("fresh.txt") == "fresh" else { return "wrong contents" }
                guard mode("kept.txt") == 0o600 else { return "kept.txt mode \(String(mode("kept.txt") ?? 0, radix: 8))" }
                guard mode("fresh.txt") == 0o666 & ~mask else { return "fresh.txt mode \(String(mode("fresh.txt") ?? 0, radix: 8))" }
                let left = try leftovers()
                return left.isEmpty ? nil : "temporary files left: \(left)"
            }),
            ("before the final rename the destination is in place and its backup is a hard link", {
                defer { unlink(at("linked.txt").path) }
                try Data("old".utf8).write(to: at("linked.txt"))
                var stage = OutputStage()
                try stage.add(Array("new".utf8), for: at("linked.txt"))
                var problem: String?
                try stage.commit { _, temporary in
                    guard contents("linked.txt") == "old" else {
                        problem = "linked.txt is \(contents("linked.txt") ?? "missing")"
                        return
                    }
                    let target = self.inode(at("linked.txt"))
                    let backups = ((try? leftovers()) ?? []).filter {
                        $0 != temporary.lastPathComponent && self.inode(at($0)) == target
                    }
                    var info = stat()
                    if backups.count != 1 || stat(at("linked.txt").path, &info) != 0 || info.st_nlink != 2 {
                        problem = "no hard-linked backup (\(backups))"
                    }
                }
                if let problem { return problem }
                guard contents("linked.txt") == "new" else { return "linked.txt is \(contents("linked.txt") ?? "missing")" }
                let left = try leftovers()
                return left.isEmpty ? nil : "temporary files left: \(left)"
            }),
            ("second rename fails after hard-link backups: first restored, second untouched, error names it", {
                try failedLinkedCommit()
            }),
            ("a path stat found that vanished fails closed", {
                do {
                    _ = try FileIO.canonical(at("vanished.txt").path, mustExist: true)
                    return "resolved"
                } catch {
                    return nil
                }
            }),
        ]
    }

    /// A child `l2dat` commits "new 1"/"new 2" over "old 1"/"old 2" and raises SIGTERM before the
    /// rename of output `index`: it must die of SIGTERM with both outputs present (old or new as
    /// renamed so far) and no temporary file or backup left.
    private func signalChecks(root: URL, executable: URL) -> [(String, () throws -> String?)] {
        [0, 1].map { index in
            ("SIGTERM before rename \(index + 1) of 2: outputs present, nothing left", {
                let manager = FileManager.default
                let directory = root.appendingPathComponent("signal-\(index)")
                try manager.createDirectory(at: directory, withIntermediateDirectories: false)
                defer { try? manager.removeItem(at: directory) }
                for number in 1...2 {
                    try Data("old \(number)".utf8).write(to: directory.appendingPathComponent("out\(number).txt"))
                }
                let child = Process()
                child.executableURL = executable
                child.arguments = [
                    "_selftest-paths", "--signal-commit", directory.path, "--signal-before-rename", "\(index)",
                ]
                try child.run()
                child.waitUntilExit()
                guard child.terminationReason == .uncaughtSignal, child.terminationStatus == SIGTERM else {
                    return "child ended with \(child.terminationReason == .exit ? "exit" : "signal") \(child.terminationStatus)"
                }
                let expected = index == 0 ? ["old 1", "old 2"] : ["new 1", "old 2"]
                for number in 1...2 {
                    let file = directory.appendingPathComponent("out\(number).txt")
                    let actual = manager.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) }
                    guard actual == expected[number - 1] else { return "out\(number).txt is \(actual ?? "missing")" }
                }
                let entries = try manager.contentsOfDirectory(atPath: directory.path).sorted()
                return entries == ["out1.txt", "out2.txt"] ? nil : "left: \(entries)"
            })
        }
    }

    /// A fresh child `l2dat` has no cleanup handler at start, and has one inside the command
    /// entry every command runs through (`Console.reportingErrors`), before any temporary file.
    private func handlerCheck(executable: URL) -> (String, () throws -> String?) {
        ("signal handlers installed at command entry, before any temporary file", {
            let child = Process()
            child.executableURL = executable
            child.arguments = ["_selftest-paths", "--probe-handlers"]
            let output = Pipe()
            child.standardOutput = output
            try child.run()
            let printed = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            child.waitUntilExit()
            guard child.terminationReason == .exit, child.terminationStatus == 0 else {
                return "child ended with status \(child.terminationStatus)"
            }
            return printed == "false true\n" ? nil : "before/at entry: \(printed.debugDescription)"
        })
    }

    /// The child side of `handlerCheck`: whether SIGTERM runs the cleanup handler before and
    /// inside `Console.reportingErrors`.
    private func probeSignalHandlers() async throws {
        let before = TemporaryFiles.isHandlingSignals
        try await Console.reportingErrors {
            print("\(before) \(TemporaryFiles.isHandlingSignals)")
        }
    }

    /// The child side of `signalChecks`. The signal is sent to the process, as from outside: this
    /// code may run on a worker thread that blocks SIGTERM, and the handler then runs on another
    /// thread, so the hook waits for it instead of returning into the rename.
    private func commitAndRaise(in directory: URL) throws {
        var stage = OutputStage()
        for number in 1...2 {
            try stage.add(Array("new \(number)".utf8), for: directory.appendingPathComponent("out\(number).txt"))
        }
        try stage.commit { index, _ in
            guard index == signalBeforeRename else { return }
            kill(getpid(), SIGTERM)
            for _ in 0..<50 { usleep(100_000) }
        }
        throw CLIError("SIGTERM did not end the process")
    }

    private func inode(_ url: URL) -> ino_t? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? info.st_ino : nil
    }

    private func matches(_ result: Result<Bool, any Error>, _ expected: Bool?) -> Bool {
        switch result {
        case let .success(same): return same == expected
        case .failure: return expected == nil
        }
    }

    private func show(_ result: Result<Bool, any Error>) -> String {
        switch result {
        case let .success(same): return "\(same)"
        case let .failure(error): return "throws (\(Console.describe(error)))"
        }
    }

    private func show(_ expected: Bool?) -> String {
        expected.map { "\($0)" } ?? "throws"
    }
}
#endif
