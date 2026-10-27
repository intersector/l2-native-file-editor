import Foundation
import SwiftUI

/// User preferences, stored in `UserDefaults` (named after the original's INI keys where one exists).
///
/// Declare it as a property of a view or of `Commands` for live updates; `AppSettings()` read on the
/// main actor outside a view returns the current stored values.
struct AppSettings: DynamicProperty {
    static let defaultChronicle = "CT2_6"
    static let defaultProtocol = 413

    /// `~/Library/Application Support/L2FileEditor/temp`.
    static var defaultTempDir: String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return support.appendingPathComponent("L2FileEditor/temp").path
    }

    /// DAT_defs sub-folder of the selected chronicle (INI `DirDDF`).
    @AppStorage("dirDDF") var chronicle = AppSettings.defaultChronicle
    /// Protocol used by Save & Encrypt (INI `Lineage2Ver`).
    @AppStorage("lineage2Ver") var protocolVersion = AppSettings.defaultProtocol
    @AppStorage("textMode") var textMode = TextMode.default
    @AppStorage("floatFormat") var floatFormat = FloatFormat.f
    /// INI `DirTmp`.
    @AppStorage("tempDir") var tempDir = AppSettings.defaultTempDir
    /// The original's "Temp Delete" option: remove this window's temp files when it closes.
    @AppStorage("deleteTempOnClose") var deleteTempOnClose = false
    /// A DAT_defs folder used instead of the bundled one; empty for the bundled set.
    @AppStorage("datDefsOverride") var datDefsOverride = ""
    /// An `l2encdec` executable used before the default helper search; empty for none.
    @AppStorage("helperOverride") var helperOverride = ""
    @AppStorage("showToolbar") var showToolbar = true
    @AppStorage("showLog") var showLog = true

    var tempDirectory: URL {
        let path = tempDir.trimmingCharacters(in: .whitespaces)
        return Self.expand(path.isEmpty ? Self.defaultTempDir : path, isDirectory: true)
    }

    var datDefsOverrideURL: URL? {
        let path = datDefsOverride.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? nil : Self.expand(path, isDirectory: true)
    }

    var helperOverrides: [URL] {
        let path = helperOverride.trimmingCharacters(in: .whitespaces)
        return path.isEmpty ? [] : [Self.expand(path, isDirectory: false)]
    }

    private static func expand(_ path: String, isDirectory: Bool) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: isDirectory)
    }
}
