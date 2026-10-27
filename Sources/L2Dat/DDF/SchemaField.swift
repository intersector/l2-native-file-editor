/// One resolved field.
public struct SchemaField: Sendable, Equatable {
    public enum Count: Sendable, Equatable {
        /// A scalar (also every compound).
        case one
        /// A static table `x[n]`.
        case fixed(Int)
        /// A dynamic table `x[ref]`; the payload is the index of the counter field.
        case dynamic(Int)
        /// `FILLER x{n}`: n bytes, one column.
        case filler(Int)
    }

    public let type: FieldType
    public let ident: String
    public let count: Count
    /// OR of AND-ed conditions; empty means always enabled.
    public let enbby: [[SchemaCondition]]
    public let ord: Int32?
    public let skipIf: [SkipIfRule]
    /// Column count of a dynamic table.
    public internal(set) var soft: Int?
    /// Mesh (MTX*) or material (MAT*) column count.
    public internal(set) var softM: Int?
    /// Texture column count (MTX*).
    public internal(set) var softT: Int?

    /// True for fields whose column count depends on data (dynamic tables and compounds).
    var needsSoftLimit: Bool {
        if case .dynamic = count { return true }
        return type.isCompound
    }

    var usesSoftT: Bool { type == .mtx || type == .mtx2 || type == .mtx3 }

    /// ENBBY evaluation against the current record's element-0 values (indexed by field).
    @inline(__always)
    func isEnabled(values: [Int64]) -> Bool {
        if enbby.isEmpty { return true }
        for line in enbby where line.allSatisfy({
            UInt32(truncatingIfNeeded: values[$0.field]) & $0.mask == $0.value
        }) {
            return true
        }
        return false
    }
}
