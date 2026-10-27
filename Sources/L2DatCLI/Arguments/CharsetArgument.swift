import ArgumentParser
import L2Dat

/// `-a <charset>` of l2disasm/l2asm: how 8-bit ASCF strings are interpreted.
enum CharsetArgument: String, CaseIterable, ExpressibleByArgument, Sendable {
    case isoLatin1 = "ISO-8859-1"
    case utf8 = "UTF-8"

    /// Accepts the iconv spellings case-insensitively (`ISO-8859-1`, `ISO8859-1`, `LATIN1`, `UTF-8`, `UTF8`).
    init?(argument: String) {
        switch argument.uppercased() {
        case "ISO-8859-1", "ISO8859-1", "ISO_8859-1", "LATIN1", "LATIN-1", "L1": self = .isoLatin1
        case "UTF-8", "UTF8": self = .utf8
        default: return nil
        }
    }

    var charset: Charset {
        switch self {
        case .isoLatin1: return .isoLatin1
        case .utf8: return .utf8
        }
    }
}
