import L2Dat

/// How FLOAT cells are printed in the disassembled text (l2disasm `-o f|e`).
enum FloatFormat: String, CaseIterable, Identifiable, Sendable {
    /// `%.8f`, the original default.
    case f
    /// `%.8e`.
    case e

    var id: String { rawValue }

    var title: String {
        switch self {
        case .f: return "Fixed (%.8f)"
        case .e: return "Scientific (%.8e)"
        }
    }

    var disasmFormat: DisasmOptions.FloatFormat {
        switch self {
        case .f: return .fixed
        case .e: return .scientific
        }
    }
}
