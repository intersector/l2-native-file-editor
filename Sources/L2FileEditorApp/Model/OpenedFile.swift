import Foundation
import L2Crypt
import L2Dat

/// The file currently shown in the editor and everything Save needs to write it back.
struct OpenedFile: Sendable {
    enum Kind: Sendable {
        /// A `.dat` table; the schema carries the effective soft limits found while disassembling
        /// (what the original kept in `<name>-new.ddf`).
        case dat(Schema)
        /// A decrypted text file (`.ini`, `.int`, `.htm`) and the encoding/BOM to write it back with.
        case text(TextCodec.Encoding)
    }

    /// The original file on disk (Save writes `<url>.bak` and then this file).
    let url: URL
    let kind: Kind
    /// Protocol named by the file's header.
    let detectedProtocol: L2Protocol
    /// Temp files of this file.
    let temp: TempLayout
    /// Text mode and float format the file was opened with; Save & Encrypt uses these, so a picker change
    /// applies on ReOpen only.
    let textMode: TextMode
    let floatFormat: FloatFormat

    var name: String { url.lastPathComponent }

    /// What Open Table shows: the temp `.txt` of a table, the decrypted copy of a text file.
    var tableURL: URL {
        switch kind {
        case .dat: return temp.txt
        case .text: return temp.decrypted
        }
    }

    /// `.dat` files are disassembled with a DDF; everything else is decrypted text.
    static func isDat(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "dat"
    }
}
