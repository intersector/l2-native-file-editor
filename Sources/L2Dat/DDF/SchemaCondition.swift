/// A resolved ENBBY condition: `(fields[field] & mask) == value`, compared as 32-bit values.
public struct SchemaCondition: Sendable, Equatable {
    public let field: Int
    public let mask: UInt32
    public let value: UInt32
    /// The value as written in the DDF (kept for export).
    let writtenValue: Int64
}
