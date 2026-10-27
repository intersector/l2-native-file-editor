import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Several outputs of one command, each written to an exclusively created temporary sibling of
/// its destination and moved into place only once all of them were written, so a failure
/// part-way leaves every destination as it was.
///
/// `commit` first gives each existing destination a backup sibling (a hard link, so the
/// destination stays in place until its own atomic rename and is never missing, even when the
/// process is interrupted; see `FileIO.backUp`), then renames every temporary file into place.
/// When a rename fails, the destinations already replaced get their backups back (new ones are
/// removed), the backups of the others are removed, the remaining temporaries are removed, and
/// the error names what was restored and any destination that could not be, with where its
/// backup is. A replaced destination keeps its file mode.
struct OutputStage {
    private typealias Backup = (url: URL, linked: Bool)

    private var staged: [(temporary: URL, destination: URL)] = []

    /// Runs `body` with a new stage and commits it; on any failure removes what was staged and
    /// rethrows, naming any temporary file that could not be removed.
    static func run<Value>(_ body: (inout OutputStage) async throws -> Value) async throws -> Value {
        var stage = OutputStage()
        do {
            let value = try await body(&stage)
            try stage.commit()
            return value
        } catch {
            throw stage.discard(after: error)
        }
    }

    /// Stages `bytes` for `destination`.
    mutating func add(_ bytes: [UInt8], for destination: URL) throws {
        let temporary = try FileIO.createTemporarySibling(of: destination)
        staged.append((temporary.url, destination))
        try FileIO.writeAndClose(bytes, to: temporary.descriptor, for: destination)
    }

    /// Stages an empty file for `destination` and returns it, for a tool that writes it by path.
    mutating func reserve(for destination: URL) throws -> URL {
        let temporary = try FileIO.createTemporarySibling(of: destination)
        close(temporary.descriptor)
        staged.append((temporary.url, destination))
        return temporary.url
    }

    /// Moves every staged file onto its destination, or none of them (see the type's comment).
    /// `beforeRename` runs just before the rename of each staged file (a self-test hook).
    mutating func commit(beforeRename: (_ index: Int, _ temporary: URL) -> Void = { _, _ in }) throws {
        var backups: [Int: Backup] = [:]
        do {
            for entry in staged {
                try FileIO.applyMode(of: entry.destination, to: entry.temporary)
            }
            for (index, entry) in staged.enumerated() {
                // A directory is not backed up: the rename onto it fails and rolls back.
                if try FileIO.isReplaceable(entry.destination) {
                    backups[index] = try FileIO.backUp(entry.destination)
                }
            }
        } catch {
            throw rollback(error, committed: 0, backups: backups)
        }
        for (index, entry) in staged.enumerated() {
            beforeRename(index, entry.temporary)
            guard rename(entry.temporary.path, entry.destination.path) == 0 else {
                let failure = CLIError("cannot write \(entry.destination.path): \(String(cString: strerror(errno)))")
                throw rollback(failure, committed: index, backups: backups)
            }
            TemporaryFiles.unregister(entry.temporary)
        }
        staged = []
        for backup in backups.sorted(by: { $0.key < $1.key }).map(\.value.url) {
            if let leftover = FileIO.remove(backup) {
                Console.warning("the outputs were written, but the previous content was kept: \(leftover)")
            }
        }
    }

    /// Undoes a commit that failed after `committed` renames, removes the temporaries and returns
    /// `error` extended with what was restored and what could not be.
    private mutating func rollback(_ error: any Error, committed: Int, backups: [Int: Backup]) -> any Error {
        var restored: [String] = []
        var problems: [String] = []
        for (index, entry) in staged.enumerated() {
            let destination = entry.destination.path
            if let backup = backups[index], backup.linked, index >= committed {
                // Not replaced: the destination still holds its data, so only the hard link goes.
                // (A rename of one link onto the other would do nothing and keep both names.)
                if let leftover = FileIO.remove(backup.url) {
                    problems.append(leftover)
                }
            } else if let backup = backups[index] {
                // From here on the backup may be the only copy of the previous content.
                TemporaryFiles.unregister(backup.url)
                // Replaces the new file when it was already moved into place.
                if rename(backup.url.path, destination) == 0 {
                    restored.append("restored \(destination)")
                } else {
                    problems.append(
                        "could not restore \(destination) (\(String(cString: strerror(errno)))); "
                            + "its previous content is in \(backup.url.path)")
                }
            } else if index < committed {
                // The destination did not exist before: remove the file this commit put there.
                if let leftover = FileIO.remove(entry.destination) {
                    problems.append(leftover)
                } else {
                    restored.append("removed the new \(destination)")
                }
            }
            if index >= committed, let leftover = FileIO.remove(entry.temporary) {
                problems.append(leftover)
            }
        }
        staged = []
        var message = Console.describe(error)
        if !restored.isEmpty { message += "; " + restored.joined(separator: ", ") }
        if !problems.isEmpty { message += "; " + problems.joined(separator: "; ") }
        return CLIError(message)
    }

    /// Removes the staged files that were not moved into place and returns `error`, extended with
    /// any of them that could not be removed.
    mutating func discard(after error: any Error) -> any Error {
        let problems = staged.compactMap { FileIO.remove($0.temporary) }
        staged = []
        guard !problems.isEmpty else { return error }
        return CLIError(Console.describe(error) + "; " + problems.joined(separator: "; "))
    }
}
