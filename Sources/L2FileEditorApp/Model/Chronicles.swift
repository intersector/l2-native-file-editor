import Foundation
import L2Crypt

/// The chronicle and protocol lists: `chronicles.json` (the original INI's `[ChronicleN*]` entries and
/// `Lineage2Ver` list) plus every other folder found in the DAT_defs directory.
struct Chronicles: Sendable {
    struct Entry: Sendable, Hashable, Identifiable, Decodable {
        let name: String
        /// Folder under DAT_defs.
        let dirDDF: String

        var id: String { dirDDF }
    }

    private struct File: Decodable {
        let protocols: [Int]
        let chronicles: [Entry]
    }

    /// DAT_defs root: the override folder or the bundled copy.
    let datDefs: URL
    let entries: [Entry]
    /// Version picker order (`413;111;414;412;411;120;121;211;212`).
    let protocols: [L2Protocol]
    /// Problems met while loading, for the log.
    let problems: [String]

    /// Reads `chronicles.json` from the app bundle and scans `override` (or the bundled DAT_defs).
    static func load(datDefsOverride override: URL?) -> Chronicles {
        let datDefs = override
            ?? Bundle.module.url(forResource: "DAT_defs", withExtension: nil)
            ?? Bundle.module.bundleURL.appendingPathComponent("DAT_defs", isDirectory: true)
        var problems: [String] = []

        var known: [Entry] = []
        var protocols = L2Protocol.allCases
        if let url = Bundle.module.url(forResource: "chronicles", withExtension: "json") {
            do {
                let file = try JSONDecoder().decode(File.self, from: Data(contentsOf: url))
                known = file.chronicles
                let listed = file.protocols.compactMap(L2Protocol.init(rawValue:))
                if !listed.isEmpty { protocols = listed }
            } catch {
                problems.append("chronicles.json could not be read: \(error.localizedDescription)")
            }
        } else {
            problems.append("chronicles.json is missing from the app bundle")
        }

        var folders: [String] = []
        do {
            folders = try FileManager.default
                .contentsOfDirectory(at: datDefs, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
                .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
                .map(\.lastPathComponent)
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        } catch {
            problems.append("DAT_defs folder \(datDefs.path) could not be read: \(error.localizedDescription)")
        }
        let knownDirs = Set(known.map { $0.dirDDF.lowercased() })
        let extra = folders
            .filter { !knownDirs.contains($0.lowercased()) }
            .map { Entry(name: $0, dirDDF: $0) }
        return Chronicles(datDefs: datDefs, entries: known + extra, protocols: protocols, problems: problems)
    }

    /// `<DAT_defs>/<dirDDF>`.
    func folder(for dirDDF: String) -> URL {
        datDefs.appendingPathComponent(dirDDF, isDirectory: true)
    }
}
