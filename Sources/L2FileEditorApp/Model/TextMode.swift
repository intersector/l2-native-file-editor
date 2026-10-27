import L2Dat

/// How 8-bit ASCF strings are read and written: the original tool's l2disasm/l2asm flag variants.
enum TextMode: String, CaseIterable, Identifiable, Sendable {
    /// No flag: `a,`/`u,` hints as found, ISO-8859-1 for 8-bit strings.
    case `default`
    /// `-f`: every ASCF as 8-bit (`a,`).
    case forceAscii
    /// `-a UTF-8`: 8-bit strings are UTF-8 bytes passed through unchanged.
    case utf8

    var id: String { rawValue }

    var title: String {
        switch self {
        case .default: return "Default"
        case .forceAscii: return "Force ASCII (-f)"
        case .utf8: return "UTF-8 (-a UTF-8)"
        }
    }

    func disasmOptions(floatFormat: FloatFormat) -> DisasmOptions {
        DisasmOptions(
            floatFormat: floatFormat.disasmFormat,
            forceAsciiHint: self == .forceAscii,
            charset: self == .utf8 ? .utf8 : .isoLatin1)
    }

    var asmOptions: AsmOptions {
        AsmOptions(forceEightBit: self == .forceAscii, charset: self == .utf8 ? .utf8 : .isoLatin1)
    }
}
