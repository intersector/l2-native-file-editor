import Darwin
import Foundation

/// File-system answers about paths: `realpath(3)` resolution and file identity. Paths are compared as
/// canonical components or `(st_dev, st_ino)`, never as normalised strings.
enum CanonicalPath {
    /// `realpath(3)` of `path`: absolute, every symlink, `.` and `..` resolved. Nil when it does not exist.
    static func real(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func components(_ path: String) -> [String] {
        path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    /// Canonical components of `url`: `realpath` of its longest existing prefix plus the missing rest.
    static func resolvedComponents(_ url: URL) -> [String] {
        var existing = url.path
        var missing: [String] = []
        while existing != "/", !exists(existing) {
            missing.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        return components(real(existing) ?? existing) + missing
    }

    /// True when `path` is an entry of the folder whose canonical components are `folder`, after
    /// resolving every symlink in it (a link pointing out of the folder, or a dangling one, is not).
    static func isEntry(_ path: String, of folder: [String]) -> Bool {
        let resolved: [String]
        if exists(path) {
            guard let real = real(path) else { return false }
            resolved = components(real)
        } else {
            let name = (path as NSString).lastPathComponent
            guard name != ".", name != "..", let parent = real((path as NSString).deletingLastPathComponent) else {
                return false
            }
            resolved = components(parent) + [name]
        }
        return resolved.count == folder.count + 1 && resolved.starts(with: folder)
    }

    /// The same file-system object (`st_dev`, `st_ino`) when both exist, else the same canonical components.
    static func sameLocation(_ lhs: URL, _ rhs: URL) -> Bool {
        var left = stat()
        var right = stat()
        if stat(lhs.path, &left) == 0, stat(rhs.path, &right) == 0 {
            return left.st_dev == right.st_dev && left.st_ino == right.st_ino
        }
        return resolvedComponents(lhs) == resolvedComponents(rhs)
    }

    /// Something (a file, folder or symlink, even a dangling one) is at `path`.
    static func exists(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }
}
