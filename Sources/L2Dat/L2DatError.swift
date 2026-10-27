/// The one error type thrown by `L2Dat`. Every case carries enough context to point at the
/// offending input: malformed DDF, `.dat` or `.txt` data always throws one of these, never traps.
public enum L2DatError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The DDF text could not be tokenised or parsed. `line`/`column` are 1-based.
    case ddfSyntax(file: String, line: Int, column: Int, message: String)
    /// The DDF parsed but cannot be resolved or used (unknown reference, missing SOFT limit, ...).
    case ddfSchema(file: String, field: String, message: String)
    /// The binary `.dat` data does not match the schema. `record` is 0-based (nil outside records),
    /// `offset` is the byte offset in the decrypted `.dat`.
    case datFormat(record: Int?, field: String?, offset: Int, message: String)
    /// The `.txt` data does not match the schema. `line` and `column` are 1-based; `column` counts
    /// Unicode scalars from the start of the line.
    case txtFormat(line: Int, column: Int, field: String?, message: String)
    /// The disassembly would exceed the output size cap: `field` has the largest soft limit
    /// (`soft` columns) and `records` rows of the resulting wide table need at least
    /// `estimatedBytes` of separators alone, over `limit`.
    case outputTooLarge(field: String, soft: Int, records: Int, estimatedBytes: Int, limit: Int)
    /// A requested feature is not available in this version.
    case unsupported(String)

    public var description: String {
        switch self {
        case let .ddfSyntax(file, line, column, message):
            return "\(file):\(line):\(column): \(message)"
        case let .ddfSchema(file, field, message):
            return "\(file): field '\(field)': \(message)"
        case let .datFormat(record, field, offset, message):
            var where_ = "dat offset \(offset)"
            if let record { where_ += ", record \(record)" }
            if let field { where_ += ", field '\(field)'" }
            return "\(where_): \(message)"
        case let .txtFormat(line, column, field, message):
            var where_ = "txt line \(line), column \(column)"
            if let field { where_ += ", field '\(field)'" }
            return "\(where_): \(message)"
        case let .outputTooLarge(field, soft, records, estimatedBytes, limit):
            return "output too large: field '\(field)' has up to \(soft) columns across \(records) records "
                + "(at least \(estimatedBytes) bytes, limit \(limit))"
        case let .unsupported(message):
            return "unsupported: \(message)"
        }
    }
}
