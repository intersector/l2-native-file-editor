/// A DDF field type keyword (MANUAL §1e.1). The raw value is the keyword as written in a DDF.
public enum FieldType: String, Sendable, CaseIterable {
    case uint = "UINT"
    case hex = "HEX"
    case int = "INT"
    case uword = "UWORD"
    case word = "WORD"
    case uchar = "UCHAR"
    case chex = "CHEX"
    case char = "CHAR"
    case float = "FLOAT"
    case unicode = "UNICODE"
    case ascf = "ASCF"
    case mat = "MAT"
    case mat2 = "MAT2"
    case mtx = "MTX"
    case mtx2 = "MTX2"
    case mtx3 = "MTX3"
    case filler = "FILLER"
    case cntr = "CNTR"

    /// Integer types: the only ones that may be referenced as a table counter or by ENBBY.
    public var isInteger: Bool {
        switch self {
        case .uint, .hex, .int, .uword, .word, .uchar, .chex, .char, .cntr: return true
        default: return false
        }
    }

    /// MTX/MTX2/MTX3/MAT/MAT2: multi-column records with their own internal counters.
    public var isCompound: Bool {
        switch self {
        case .mat, .mat2, .mtx, .mtx2, .mtx3: return true
        default: return false
        }
    }
}
