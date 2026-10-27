/// One field of a DDF body, as written (identifiers not yet resolved).
public struct DDFField: Sendable, Equatable {
    public var type: FieldType
    public var ident: String
    public var table: TableSpec
    /// ENBBY lines (OR-ed); the conditions inside one line are AND-ed.
    public var enbby: [[EnbbyCondition]]
    /// `ORD`; `-1` means OFF. `nil` when absent.
    public var ord: Int32?
    public var skipIf: [SkipIfRule]
    public var soft: Int?
    public var softM: Int?
    public var softT: Int?
    /// 1-based DDF line of the type keyword.
    public var line: Int

    public init(
        type: FieldType, ident: String, table: TableSpec = .none, enbby: [[EnbbyCondition]] = [],
        ord: Int32? = nil, skipIf: [SkipIfRule] = [], soft: Int? = nil, softM: Int? = nil,
        softT: Int? = nil, line: Int = 0
    ) {
        self.type = type
        self.ident = ident
        self.table = table
        self.enbby = enbby
        self.ord = ord
        self.skipIf = skipIf
        self.soft = soft
        self.softM = softM
        self.softT = softT
        self.line = line
    }
}
