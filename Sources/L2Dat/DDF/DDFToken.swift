/// A DDF token. Words cover identifiers, numbers, `..` and the literals NO/YES/OFF; the parser
/// classifies them by position.
struct DDFToken {
    enum Kind: Equatable {
        case word
        case string
        case punct(UInt8)
        case end
    }

    var kind: Kind
    /// Word bytes, or the decoded bytes of a string literal.
    var text: [UInt8]
    var line: Int
    var column: Int

    var string: String { String(decoding: text, as: UTF8.self) }

    func isPunct(_ byte: UInt8) -> Bool { kind == .punct(byte) }
}
