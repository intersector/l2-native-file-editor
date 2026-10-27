import Foundation

/// Names of the temp files of one opened file, as the original laid them out in its temp folder.
/// `dir` is a per-window subfolder `<Temp folder>/<UUID>`, so windows never share or overwrite temp files.
/// `base` and `dir` are canonical (`realpath`) paths, fixed when the file is opened.
struct TempLayout: Sendable, Hashable {
    let base: URL
    let dir: URL
    let fileName: String

    /// Working copy of the original (`<name>`).
    var copy: URL { dir.appendingPathComponent(fileName) }
    /// Decrypted file (`dec-<name>`).
    var decrypted: URL { dir.appendingPathComponent("dec-" + fileName) }
    /// Encrypted output of Save before it replaces the original (`enc-<name>`).
    var encrypted: URL { dir.appendingPathComponent("enc-" + fileName) }
    /// Disassembled table (`<base>.txt`), shown by Open Table.
    var txt: URL { dir.appendingPathComponent(baseName + ".txt") }
    /// Schema with effective soft limits (`<base>-new.ddf`).
    var newDDF: URL { dir.appendingPathComponent(baseName + "-new.ddf") }

    var baseName: String { (fileName as NSString).deletingPathExtension }

    /// `<base>/<id>`: the temp subfolder of one window.
    static func sessionDir(base: URL, id: UUID) -> URL {
        base.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// Creates the Temp folder `base` and the window's subfolder `<base>/<id>` when missing, resolves both
    /// with `realpath` and returns the layout of `fileName` in it.
    ///
    /// Throws `.tempFolderIsSourceFolder` when `base`, the subfolder or the working copy is `source` or the
    /// folder holding it, `.sourceInTempSession` when `source` lies inside any window's temp subfolder
    /// (deleted when that window closes), and `.tempPathEscapes` when the subfolder or a temp file resolves
    /// to a place outside `<base>/<id>`. Only creates folders, so call it before any copy or delete.
    static func prepare(base: URL, id: UUID, fileName: String, source: URL) throws -> TempLayout {
        let canonicalBase = try canonicalFolder(base)
        let layout = TempLayout(
            base: canonicalBase, dir: sessionDir(base: canonicalBase, id: id), fileName: fileName)
        try layout.protect(source)
        try layout.prepareDir()
        return layout
    }

    /// Re-checks the layout before each use: the Temp folder still exists as a folder at the same canonical
    /// path (recreated when it was deleted), and the subfolder and every temp file still resolve inside it.
    /// Throws `.tempFolderChanged` when the Temp folder now resolves elsewhere (replaced by a link).
    func revalidate(source: URL) throws {
        guard CanonicalPath.components(try Self.canonicalFolder(base).path) == CanonicalPath.components(base.path) else {
            throw PipelineError.tempFolderChanged(path: base.path)
        }
        try protect(source)
        try prepareDir()
    }

    /// Creates `url` (and its parents) when missing and returns its `realpath`; it must be a folder.
    private static func canonicalFolder(_ url: URL) throws -> URL {
        try PipelineError.wrap("create the temp folder", url) {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        var isDirectory: ObjCBool = false
        guard let real = CanonicalPath.real(url.path),
              FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw PipelineError.fileSystem(action: "use the temp folder", path: url.path, reason: "it is not a folder")
        }
        return URL(fileURLWithPath: real, isDirectory: true)
    }

    /// Creates `dir` when missing; it and every temp file must resolve inside it (`dir` itself inside `base`).
    private func prepareDir() throws {
        try PipelineError.wrap("create the temp folder", dir) {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let expected = CanonicalPath.components(base.path) + [dir.lastPathComponent]
        guard CanonicalPath.real(dir.path).map(CanonicalPath.components) == expected else {
            throw PipelineError.tempPathEscapes(path: dir.path)
        }
        let dirComponents = CanonicalPath.components(dir.path)
        for file in [copy, decrypted, encrypted, txt, newDDF] where !CanonicalPath.isEntry(file.path, of: dirComponents) {
            throw PipelineError.tempPathEscapes(path: file.path)
        }
    }

    private func protect(_ source: URL) throws {
        let protected = [source, source.deletingLastPathComponent()]
        for candidate in [base, dir, copy] {
            for original in protected where CanonicalPath.sameLocation(candidate, original) {
                throw PipelineError.tempFolderIsSourceFolder(path: candidate.path)
            }
        }
        var child = URL(fileURLWithPath: "/" + CanonicalPath.resolvedComponents(source).joined(separator: "/"))
        while child.path != "/" {
            let parent = child.deletingLastPathComponent()
            if UUID(uuidString: child.lastPathComponent) != nil, CanonicalPath.sameLocation(parent, base) {
                throw PipelineError.sourceInTempSession(path: source.path)
            }
            child = parent
        }
    }
}
