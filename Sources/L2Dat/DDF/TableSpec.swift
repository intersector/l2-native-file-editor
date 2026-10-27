/// The bracket suffix of a field: `x`, `x[8]`, `x[cnt]` or `x{360}` (FILLER).
public enum TableSpec: Sendable, Equatable {
    case none
    case fixed(Int)
    case dynamic(String)
    case filler(Int)
}
