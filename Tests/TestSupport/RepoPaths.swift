import Foundation

public enum RepoPaths {
    /// Repository root: this file is `<root>/Tests/TestSupport/RepoPaths.swift`, three levels up.
    public static let root: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// Golden corpus folder; `L2DAT_FIXTURES` overrides the default `<root>/fixtures/high5`.
    public static let fixtures: URL = {
        if let override = ProcessInfo.processInfo.environment["L2DAT_FIXTURES"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return root.appendingPathComponent("fixtures/high5", isDirectory: true)
    }()

    /// Committed DDF definitions shipped with the app (synced from upstream by `scripts/sync-dat-defs.sh`).
    public static let datDefs: URL = root.appendingPathComponent(
        "Sources/L2FileEditorApp/Resources/DAT_defs", isDirectory: true)

    /// True when the gitignored game data (`enc/`, `dec/`, `txt/`) and `RESULTS.tsv` are present.
    public static var fixturesAvailable: Bool {
        let fm = FileManager.default
        for sub in ["enc", "dec", "txt"] {
            var isDir: ObjCBool = false
            let path = fixtures.appendingPathComponent(sub).path
            guard fm.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return false }
        }
        return fm.fileExists(atPath: fixtures.appendingPathComponent("RESULTS.tsv").path)
    }
}
