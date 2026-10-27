import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// File access that throws readable `CLIError`s instead of Foundation's error descriptions.
enum FileIO {
    /// The file the shell would open for `path`. A relative path is prefixed with the current
    /// directory as a string: `URL(fileURLWithPath:)` would collapse its `..` lexically, which is
    /// not where `jump/../x` lands when `jump` is a symlink.
    static func url(_ path: String) -> URL {
        if path.hasPrefix("/") { return URL(fileURLWithPath: path) }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath + "/" + path)
    }

    static func read(_ url: URL) throws -> [UInt8] {
        try requireInputFile(url)
        do {
            return [UInt8](try Data(contentsOf: url))
        } catch {
            throw CLIError("cannot read \(url.path): \(reason(error))")
        }
    }

    /// Writes `bytes` through a temporary sibling renamed onto `url` (see `OutputStage`).
    static func write(_ bytes: [UInt8], to url: URL) async throws {
        try requireOutputDirectory(url)
        try await OutputStage.run { try $0.add(bytes, for: url) }
    }

    static func requireInputFile(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw CLIError("\(url.path): no such file")
        }
        guard !isDirectory.boolValue else { throw CLIError("\(url.path): is a directory, expected a file") }
    }

    static func requireDirectory(_ url: URL) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("\(url.path): no such directory")
        }
    }

    /// The directory `output` goes into must exist and be writable, and `output` itself must not
    /// be a directory or be spelled as one (`x.txt/`).
    static func requireOutputDirectory(_ output: URL) throws {
        var isDirectory: ObjCBool = false
        if output.hasDirectoryPath || [".", ".."].contains(output.lastPathComponent)
            || (FileManager.default.fileExists(atPath: output.path, isDirectory: &isDirectory) && isDirectory.boolValue)
        {
            throw CLIError("cannot write \(output.path)/: is a directory, expected a file")
        }
        let parent = output.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CLIError("cannot write \(output.path): directory \(parent.path) does not exist")
        }
        try requireWritableDirectory(parent, for: output)
    }

    /// A directory that does not exist yet must be creatable (its nearest existing ancestor is a
    /// writable directory); an existing one must be a writable directory. The spelled path is
    /// walked component by component (the kernel resolves each prefix, so `..` after a symlink is
    /// physical); a `..` below a directory that does not exist is refused, since it only exists
    /// once that directory is created. The walk visits each component once, so it always ends.
    static func requireCreatableDirectory(_ directory: URL) throws {
        let path = spelling(directory)
        var ancestor = "/"
        var missing: String?
        for component in path.split(separator: "/").map(String.init) where component != "." {
            if let missing {
                if component == ".." {
                    throw CLIError(
                        "cannot create directory \(path): '..' follows \(missing), which does not exist")
                }
                continue
            }
            let prefix = joined(ancestor, [component])
            var info = stat()
            guard stat(prefix, &info) == 0 else {
                let code = errno
                guard code == ENOENT else {
                    throw CLIError("cannot create directory \(path): \(prefix): \(String(cString: strerror(code)))")
                }
                missing = prefix
                continue
            }
            guard info.st_mode & S_IFMT == S_IFDIR else {
                throw CLIError("cannot create directory \(path): \(prefix) is not a directory")
            }
            ancestor = prefix
        }
        try requireWritableDirectory(URL(fileURLWithPath: ancestor), for: directory)
    }

    /// Creating, replacing and renaming entries needs write and search permission on the directory.
    private static func requireWritableDirectory(_ directory: URL, for target: URL) throws {
        guard access(directory.path, W_OK | X_OK) == 0 else {
            throw CLIError("cannot write \(target.path): directory \(directory.path): \(String(cString: strerror(errno)))")
        }
    }

    static func requireDistinct(input: URL, output: URL) throws {
        if try samePath(input, output) {
            throw CLIError("output \(output.path) would overwrite the input; choose another output file")
        }
    }

    /// An output must not replace the DDF the command was told to read.
    static func requireNotSchema(_ output: URL, schema: URL) throws {
        if try samePath(schema, output) {
            throw CLIError("output \(output.path) would overwrite the DDF; choose another output file")
        }
    }

    /// The `-e` export must not be the input, the DDF or the main output, and its directory must
    /// exist and be writable, so a bad export is caught before anything is written.
    static func requireExport(_ export: URL, input: URL, output: URL, schema: URL) throws {
        if try samePath(schema, export) {
            throw CLIError("export \(export.path) would overwrite the DDF; choose another export file")
        }
        if try samePath(input, export) {
            throw CLIError("export \(export.path) would overwrite the input; choose another export file")
        }
        if try samePath(output, export) {
            throw CLIError("export \(export.path) would overwrite the output; choose another export file")
        }
        try requireOutputDirectory(export)
    }

    /// Mode of a new output: what `creat(path, 0666)` would give under the current umask.
    private static let creationMode: mode_t = {
        let mask = umask(0)
        umask(mask)
        return 0o666 & ~mask
    }()

    /// A random hidden name for a temporary file: `.l2dat-<16 hex digits>.tmp`. It does not
    /// depend on the destination's name, so a destination name up to NAME_MAX still works.
    static func randomTemporaryName() -> String {
        let digits = String(UInt64.random(in: .min ... .max), radix: 16)
        return ".l2dat-" + String(repeating: "0", count: 16 - digits.count) + digits + ".tmp"
    }

    /// Creates a new, empty temporary file next to `destination` (same directory, so a rename onto
    /// it is atomic) with `open(O_CREAT | O_EXCL)` and mode 0600: an existing file is never
    /// opened, truncated or removed; another random name is tried instead. The file is registered
    /// for removal on SIGINT/SIGTERM/SIGHUP. Returns the file and its open descriptor.
    static func createTemporarySibling(
        of destination: URL, names: () -> String = randomTemporaryName
    ) throws -> (url: URL, descriptor: Int32) {
        // Commands install the handlers at start; this only covers a caller that did not.
        TemporaryFiles.installHandlers()
        let directory = destination.deletingLastPathComponent()
        for _ in 0..<attempts {
            let candidate = directory.appendingPathComponent(names(), isDirectory: false)
            let descriptor = open(candidate.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC, 0o600)
            if descriptor >= 0 {
                // Registered only once created: on EEXIST the name is not ours to unlink. A signal
                // handled on another thread before this line leaves the file behind (see `TemporaryFiles`).
                TemporaryFiles.register(candidate)
                return (candidate, descriptor)
            }
            let code = errno
            guard code == EEXIST else {
                throw CLIError("cannot write \(destination.path): \(String(cString: strerror(code)))")
            }
        }
        throw CLIError(
            "cannot write \(destination.path): no free temporary file name in \(directory.path) after \(attempts) attempts")
    }

    private static let attempts = 16

    /// Writes all of `bytes` to `descriptor` and closes it.
    static func writeAndClose(_ bytes: [UInt8], to descriptor: Int32, for destination: URL) throws {
        var failure: Int32?
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = systemWrite(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if close(descriptor) != 0, failure == nil { failure = errno }
        if let failure {
            throw CLIError("cannot write \(destination.path): \(String(cString: strerror(failure)))")
        }
    }

    /// Gives `temporary` the mode `destination` has now, or the mode a new file would get, so
    /// replacing a 0600 output keeps it 0600.
    static func applyMode(of destination: URL, to temporary: URL) throws {
        var info = stat()
        let mode: mode_t
        if stat(destination.path, &info) == 0 {
            mode = info.st_mode & 0o777
        } else {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw CLIError("cannot write \(destination.path): \(String(cString: strerror(code)))")
            }
            mode = creationMode
        }
        guard chmod(temporary.path, mode) == 0 else {
            throw CLIError("cannot write \(destination.path): \(String(cString: strerror(errno)))")
        }
    }

    /// Whether `destination` exists as something a rename would replace (not a directory).
    static func isReplaceable(_ destination: URL) throws -> Bool {
        var info = stat()
        guard lstat(destination.path, &info) == 0 else {
            let code = errno
            guard code == ENOENT || code == ENOTDIR else {
                throw CLIError("cannot write \(destination.path): \(String(cString: strerror(code)))")
            }
            return false
        }
        return info.st_mode & S_IFMT != S_IFDIR
    }

    /// A backup of the existing `destination` under a new hidden sibling name, for `OutputStage`.
    /// It is a hard link (`linked`), so `destination` stays in place until the atomic rename that
    /// replaces it: an interruption never leaves it missing. Such a backup is registered for signal
    /// cleanup, since the destination holds the data until that rename. On a file system that
    /// refuses the hard link (EXDEV, EPERM, EMLINK, ENOTSUP), `destination` is renamed to an
    /// exclusively created sibling instead; that backup is then the only copy, so it is not
    /// registered. A symbolic link is backed up as itself, not followed.
    static func backUp(
        _ destination: URL, names: () -> String = randomTemporaryName
    ) throws -> (url: URL, linked: Bool) {
        let directory = destination.deletingLastPathComponent()
        for _ in 0..<attempts {
            let candidate = directory.appendingPathComponent(names(), isDirectory: false)
            // linkat(2) fails with EEXIST rather than replace an existing name: exclusive like O_EXCL.
            if linkat(AT_FDCWD, destination.path, AT_FDCWD, candidate.path, 0) == 0 {
                TemporaryFiles.register(candidate)
                return (candidate, true)
            }
            let code = errno
            switch code {
            case EEXIST:
                continue
            case EXDEV, EPERM, EMLINK, ENOTSUP, EOPNOTSUPP:
                return (try moveAside(destination), false)
            default:
                throw CLIError(
                    "cannot write \(destination.path): cannot back up the existing file: \(String(cString: strerror(code)))")
            }
        }
        throw CLIError(
            "cannot write \(destination.path): no free temporary file name in \(directory.path) after \(attempts) attempts")
    }

    /// Renames the existing `destination` to a new, exclusively created hidden sibling and returns
    /// that backup. The backup holds the user's data, so it is not registered for signal cleanup.
    private static func moveAside(_ destination: URL) throws -> URL {
        let (backup, descriptor) = try createTemporarySibling(of: destination)
        TemporaryFiles.unregister(backup)
        close(descriptor)
        guard rename(destination.path, backup.path) == 0 else {
            let message = String(cString: strerror(errno))
            var detail = "cannot write \(destination.path): cannot move the existing file aside: \(message)"
            if let leftover = remove(backup) { detail += "; \(leftover)" }
            throw CLIError(detail)
        }
        return backup
    }

    /// Removes a file this process created. nil when it is gone (also when it was already
    /// missing); otherwise a message naming the leftover file.
    static func remove(_ url: URL) -> String? {
        guard unlink(url.path) != 0 else {
            TemporaryFiles.unregister(url)
            return nil
        }
        let code = errno
        if code == ENOENT {
            TemporaryFiles.unregister(url)
            return nil
        }
        return "could not remove \(url.path): \(String(cString: strerror(code)))"
    }

    /// Whether `lhs` and `rhs` name the same file, also when it does not exist yet. Two existing
    /// paths are compared by device and inode. Otherwise each path is resolved component by
    /// component on the file system (symlinks, `..`, on-disk letter case); only components below a
    /// directory that does not exist are kept as spelled, and a `..` that climbs back out of them
    /// returns to the file system. The two are compared under the volume's case rule.
    /// Fails closed: a path the file system cannot resolve for a reason other than a missing
    /// component (EACCES, ELOOP, EIO, ...) throws instead of being compared by its spelling.
    static func samePath(_ lhs: URL, _ rhs: URL) throws -> Bool {
        let lhsPath = spelling(lhs)
        let rhsPath = spelling(rhs)
        let lhsID = try FileID(lhsPath)
        let rhsID = try FileID(rhsPath)
        if let lhsID, let rhsID {
            return lhsID == rhsID
        }
        // A path stat just found must still resolve; if it vanished, the comparison fails closed.
        let lhsCanonical = try canonical(lhsPath, mustExist: lhsID != nil)
        let rhsCanonical = try canonical(rhsPath, mustExist: rhsID != nil)
        if lhsCanonical.caseInsensitive || rhsCanonical.caseInsensitive {
            return lhsCanonical.path.compare(rhsCanonical.path, options: .caseInsensitive) == .orderedSame
        }
        return lhsCanonical.path == rhsCanonical.path
    }

    /// The absolute path as spelled. A relative URL's `path` has its `..` collapsed lexically by
    /// Foundation, so it is rebuilt from the base directory and the `relativePath` as given.
    static func spelling(_ url: URL) -> String {
        guard let base = url.baseURL else { return url.path }
        return base.path + "/" + url.relativePath
    }

    private struct FileID: Equatable {
        let device: dev_t
        let inode: ino_t

        /// nil when the path does not exist (ENOENT, ENOTDIR); any other failure throws.
        init?(_ path: String) throws {
            var info = stat()
            guard stat(path, &info) == 0 else {
                try FileIO.requireMissing(path)
                return nil
            }
            device = info.st_dev
            inode = info.st_ino
        }
    }

    /// Throws unless the call that just failed did so because a component does not exist.
    private static func requireMissing(_ path: String) throws {
        let code = errno
        guard code == ENOENT || code == ENOTDIR else {
            throw CLIError("cannot resolve path \(path): \(String(cString: strerror(code)))")
        }
    }

    /// `path` resolved on the file system component by component, plus whether names on the
    /// volume of its deepest existing directory compare case-insensitively. Components below a
    /// missing directory are kept as spelled (`..` of a directory that does not exist yet is only
    /// reachable once it is created); once `..` climbs back to an existing directory, the
    /// following components are resolved by the file system again. With `mustExist` (stat found
    /// `path` a moment ago), a component that no longer exists throws instead.
    static func canonical(_ path: String, mustExist: Bool = false) throws -> (path: String, caseInsensitive: Bool) {
        var anchor = "/"
        var missing: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            switch component {
            case ".":
                continue
            case "..":
                if !missing.isEmpty {
                    missing.removeLast()
                } else if let slash = anchor.lastIndex(of: "/") {
                    // `anchor` comes from realpath: no symlinks left, so its parent is lexical.
                    anchor = slash == anchor.startIndex ? "/" : String(anchor[..<slash])
                }
            default:
                if missing.isEmpty, let resolved = try realPath(joined(anchor, [component]), of: path) {
                    anchor = resolved
                } else if mustExist {
                    throw CLIError("cannot resolve path \(path): \(String(cString: strerror(ENOENT))) (it existed a moment ago)")
                } else {
                    missing.append(component)
                }
            }
        }
        return (joined(anchor, missing), isCaseInsensitiveVolume(anchor))
    }

    private static func joined(_ directory: String, _ components: [String]) -> String {
        components.reduce(directory) { $0 == "/" ? "/" + $1 : $0 + "/" + $1 }
    }

    /// nil when `candidate` does not exist; any other failure throws, naming the full `path`.
    private static func realPath(_ candidate: String, of path: String) throws -> String? {
        guard let resolved = realpath(candidate, nil) else {
            try requireMissing(path)
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// APFS and HFS+ default to case-insensitive names. Linux is treated as case-sensitive: a
    /// case-insensitive mount there (vfat, exfat, ext4 casefold, CIFS) is not detected, so two
    /// spellings of a file that does not exist yet that differ only in case compare as different
    /// (existing files are compared by inode and are not affected).
    private static func isCaseInsensitiveVolume(_ path: String) -> Bool {
        #if canImport(Darwin)
        let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        return !(values?.volumeSupportsCaseSensitiveNames ?? false)
        #else
        return false
        #endif
    }

    static func createDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw CLIError("cannot create directory \(url.path): \(reason(error))")
        }
    }

    /// `<directory of input>/<prefix><name of input>`, like l2encdec's default `dec-`/`enc-` names.
    static func prefixed(_ input: URL, with prefix: String) -> URL {
        input.deletingLastPathComponent().appendingPathComponent(prefix + input.lastPathComponent)
    }

    /// The POSIX reason when Foundation wraps one, else Foundation's description.
    private static func reason(_ error: any Error) -> String {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, underlying.domain == NSPOSIXErrorDomain {
            return String(cString: strerror(Int32(underlying.code)))
        }
        return nsError.localizedDescription
    }
}

/// `write(2)`; `FileIO.write` hides the unqualified name inside `FileIO`.
private func systemWrite(_ descriptor: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
    #if canImport(Darwin)
    return Darwin.write(descriptor, buffer, count)
    #else
    return Glibc.write(descriptor, buffer, count)
    #endif
}
