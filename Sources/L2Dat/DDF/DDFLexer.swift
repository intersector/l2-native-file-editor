
/// Byte-level DDF tokenizer: skips whitespace and `/* */`, `//`, `#` comments.
struct DDFLexer {
    private let bytes: [UInt8]
    private let fileName: String
    private var pos = 0
    private var line = 1
    private var lineStart = 0

    init(bytes: [UInt8], fileName: String) {
        self.bytes = bytes
        self.fileName = fileName
    }

    /// Characters that end a word (MANUAL §1e.2: whitespace and `[](){}=,/*\#:;`, plus `"`).
    private static let delimiters: [Bool] = {
        var table = [Bool](repeating: false, count: 256)
        for byte in 0...0x20 { table[byte] = true }
        for char in "[](){}=,/*\\#:;\"".utf8 { table[Int(char)] = true }
        return table
    }()

    private static let punctuation: Set<UInt8> = Set("{}[]()=,;:".utf8)

    func error(_ message: String, line: Int, column: Int) -> L2DatError {
        .ddfSyntax(file: fileName, line: line, column: column, message: message)
    }

    mutating func next() throws -> DDFToken {
        try skipTrivia()
        let column = pos - lineStart + 1
        guard pos < bytes.count else { return DDFToken(kind: .end, text: [], line: line, column: column) }
        let byte = bytes[pos]
        if Self.punctuation.contains(byte) {
            pos += 1
            return DDFToken(kind: .punct(byte), text: [byte], line: line, column: column)
        }
        if byte == UInt8(ascii: "\"") { return try stringLiteral(column: column) }
        if Self.delimiters[Int(byte)] {
            throw error("unexpected character '\(Character(Unicode.Scalar(byte)))'", line: line, column: column)
        }
        let start = pos
        while pos < bytes.count, !Self.delimiters[Int(bytes[pos])] { pos += 1 }
        return DDFToken(kind: .word, text: Array(bytes[start..<pos]), line: line, column: column)
    }

    private mutating func skipTrivia() throws {
        while pos < bytes.count {
            let byte = bytes[pos]
            if byte == 0x0A {
                pos += 1
                line += 1
                lineStart = pos
            } else if byte <= 0x20 {
                pos += 1
            } else if byte == UInt8(ascii: "#") {
                skipLine()
            } else if byte == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "/") {
                skipLine()
            } else if byte == UInt8(ascii: "/"), pos + 1 < bytes.count, bytes[pos + 1] == UInt8(ascii: "*") {
                let startLine = line, startColumn = pos - lineStart + 1
                pos += 2
                while true {
                    guard pos + 1 < bytes.count else {
                        throw error("unterminated comment", line: startLine, column: startColumn)
                    }
                    if bytes[pos] == UInt8(ascii: "*"), bytes[pos + 1] == UInt8(ascii: "/") {
                        pos += 2
                        break
                    }
                    if bytes[pos] == 0x0A {
                        line += 1
                        lineStart = pos + 1
                    }
                    pos += 1
                }
            } else {
                return
            }
        }
    }

    private mutating func skipLine() {
        while pos < bytes.count, bytes[pos] != 0x0A { pos += 1 }
    }

    /// `"..."`: `\t` is a tab, any other `\x` quotes `x` (MANUAL §1d.1).
    private mutating func stringLiteral(column: Int) throws -> DDFToken {
        let startLine = line
        pos += 1
        var text: [UInt8] = []
        while true {
            guard pos < bytes.count, bytes[pos] != 0x0A else {
                throw error("unterminated string literal", line: startLine, column: column)
            }
            let byte = bytes[pos]
            pos += 1
            if byte == UInt8(ascii: "\"") { break }
            if byte == UInt8(ascii: "\\"), pos < bytes.count, bytes[pos] != 0x0A {
                let quoted = bytes[pos]
                pos += 1
                text.append(quoted == UInt8(ascii: "t") ? 0x09 : quoted)
            } else {
                text.append(byte)
            }
        }
        return DDFToken(kind: .string, text: text, line: startLine, column: column)
    }
}
