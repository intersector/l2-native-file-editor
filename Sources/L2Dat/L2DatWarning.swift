/// A non-fatal observation made while disassembling or assembling (the output is still produced).
public struct L2DatWarning: Sendable, Equatable, CustomStringConvertible {
    /// 1-based txt line (assembly) when known.
    public let line: Int?
    /// 0-based record index (disassembly) when known.
    public let record: Int?
    public let field: String?
    public let message: String

    public init(line: Int? = nil, record: Int? = nil, field: String? = nil, message: String) {
        self.line = line
        self.record = record
        self.field = field
        self.message = message
    }

    public var description: String {
        var parts: [String] = []
        if let line { parts.append("line \(line)") }
        if let record { parts.append("record \(record)") }
        if let field { parts.append("field '\(field)'") }
        return parts.isEmpty ? message : parts.joined(separator: ", ") + ": " + message
    }
}
