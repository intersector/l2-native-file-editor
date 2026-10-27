/// Recursive-descent DDF parser: `control* '{' (field property*)* '}'`; anything after the
/// closing brace is ignored (never even tokenised).
struct DDFParser {
    private var lexer: DDFLexer
    private var lookahead: DDFToken?
    private let fileName: String

    private static let propertyNames: Set<String> = ["ENBBY", "ORD", "SKIPIF", "SOFT", "SOFTM", "SOFTT"]

    init(bytes: [UInt8], fileName: String) {
        lexer = DDFLexer(bytes: bytes, fileName: fileName)
        self.fileName = fileName
    }

    mutating func parse() throws -> DDFDocument {
        var document = DDFDocument(fileName: fileName)
        while true {
            let token = try take()
            if token.isPunct(UInt8(ascii: "{")) { break }
            guard token.kind == .word else {
                throw error("expected a control variable or '{'", at: token)
            }
            try parseControl(name: token, into: &document.controls)
        }
        while true {
            let token = try take()
            switch token.kind {
            case .punct(UInt8(ascii: "}")):
                return document
            case .punct(UInt8(ascii: ";")):
                continue
            case .word:
                if try peek().isPunct(UInt8(ascii: "=")) {
                    guard !document.fields.isEmpty else {
                        throw error("property '\(token.string)' before any field", at: token)
                    }
                    try parseProperty(name: token, into: &document.fields[document.fields.count - 1])
                } else {
                    document.fields.append(try parseField(typeToken: token))
                }
            case .end:
                throw error("missing closing '}'", at: token)
            default:
                throw error("expected a field or '}'", at: token)
            }
        }
    }

    // MARK: - Controls

    private mutating func parseControl(name: DDFToken, into controls: inout DDFControls) throws {
        try expect(UInt8(ascii: "="))
        let value = try take()
        switch name.string {
        case "FS":
            guard value.kind == .string, !value.text.isEmpty, !value.text.contains(0x0A) else {
                throw error("FS must be a non-empty string literal", at: value)
            }
            controls.fs = value.text
        case "RECCNT":
            let count = try integer(value)
            guard count >= -1 else { throw error("RECCNT must be OFF or a record count", at: value) }
            controls.recCnt = Int(count)
        case "HEADER": controls.header = try integer(value) != 0
        case "MTXCNT_OUT": controls.mtxCntOut = try integer(value) != 0
        case "MATCNT_OUT": controls.matCntOut = try integer(value) != 0
        case "ORD_IGNORE": controls.ordIgnore = try integer(value) != 0
        case "MAGIC":
            let magic = try integer(value)
            guard magic >= 0, magic <= 0xFFFF else { throw error("MAGIC out of range", at: value) }
            controls.magic = Int(magic)
        default:
            throw error("unknown control variable '\(name.string)'", at: name)
        }
        try expect(UInt8(ascii: ";"))
    }

    // MARK: - Fields

    private mutating func parseField(typeToken: DDFToken) throws -> DDFField {
        guard let type = FieldType(rawValue: typeToken.string) else {
            throw error("unknown field type '\(typeToken.string)'", at: typeToken)
        }
        let identToken = try take()
        guard identToken.kind == .word else { throw error("expected a field name", at: identToken) }
        var field = DDFField(type: type, ident: identToken.string, line: typeToken.line)
        let next = try peek()
        if next.isPunct(UInt8(ascii: "[")) {
            _ = try take()
            let size = try take()
            guard size.kind == .word else { throw error("expected a table size", at: size) }
            if let count = Self.integerValue(size.text) {
                guard count >= 0, count <= 0x100000 else { throw error("table size out of range", at: size) }
                field.table = .fixed(Int(count))
            } else {
                field.table = .dynamic(size.string)
            }
            try expect(UInt8(ascii: "]"))
        } else if next.isPunct(UInt8(ascii: "{")) {
            _ = try take()
            let size = try take()
            guard let count = Self.integerValue(size.text), count >= 0, count <= 0x100000 else {
                throw error("expected a FILLER byte count", at: size)
            }
            field.table = .filler(Int(count))
            try expect(UInt8(ascii: "}"))
        }
        if type == .filler {
            guard case .filler = field.table else { throw error("FILLER needs a {count}", at: identToken) }
        } else if case .filler = field.table {
            throw error("only FILLER takes a {count}", at: identToken)
        }
        try expect(UInt8(ascii: ";"))
        return field
    }

    private mutating func parseProperty(name: DDFToken, into field: inout DDFField) throws {
        try expect(UInt8(ascii: "="))
        switch name.string {
        case "SOFT": field.soft = try softLimit()
        case "SOFTM": field.softM = try softLimit()
        case "SOFTT": field.softT = try softLimit()
        case "ORD":
            let token = try take()
            let ord = try integer(token)
            guard ord >= -1, ord <= Int64(Int32.max) else { throw error("ORD out of range", at: token) }
            field.ord = Int32(ord)
        case "ENBBY": field.enbby.append(try enbbyList())
        case "SKIPIF": field.skipIf.append(contentsOf: try skipIfList())
        default:
            throw error("unknown property '\(name.string)'", at: name)
        }
        try expect(UInt8(ascii: ";"))
    }

    private mutating func softLimit() throws -> Int {
        let token = try take()
        let value = try integer(token)
        guard value >= 0, value <= 0x100000 else { throw error("soft limit out of range", at: token) }
        return Int(value)
    }

    /// `[(ref[:mask], value), ...]`
    private mutating func enbbyList() throws -> [EnbbyCondition] {
        try expect(UInt8(ascii: "["))
        var conditions: [EnbbyCondition] = []
        repeat {
            try expect(UInt8(ascii: "("))
            let ref = try take()
            guard ref.kind == .word, Self.integerValue(ref.text) == nil else {
                throw error("expected a field name in ENBBY", at: ref)
            }
            var mask: Int32 = -1
            if try peek().isPunct(UInt8(ascii: ":")) {
                _ = try take()
                let token = try take()
                let value = try integer(token)
                guard value >= Int64(Int32.min), value <= Int64(UInt32.max) else {
                    throw error("ENBBY mask out of range", at: token)
                }
                mask = Int32(truncatingIfNeeded: value)
            }
            try expect(UInt8(ascii: ","))
            let value = try integer(try take())
            try expect(UInt8(ascii: ")"))
            conditions.append(EnbbyCondition(ref: ref.string, mask: mask, value: value))
        } while try takeIf(UInt8(ascii: ","))
        try expect(UInt8(ascii: "]"))
        return conditions
    }

    /// `[(index[ .. index], value[ .. value]), ...]`
    private mutating func skipIfList() throws -> [SkipIfRule] {
        try expect(UInt8(ascii: "["))
        var rules: [SkipIfRule] = []
        repeat {
            try expect(UInt8(ascii: "("))
            let (indexLow, indexHigh) = try range()
            try expect(UInt8(ascii: ","))
            let (valueLow, valueHigh) = try range()
            try expect(UInt8(ascii: ")"))
            guard let low = Int(exactly: indexLow), let high = Int(exactly: indexHigh) else {
                throw error("SKIPIF index must be an integer", at: try peek())
            }
            rules.append(SkipIfRule(indexLow: low, indexHigh: high, valueLow: valueLow, valueHigh: valueHigh))
        } while try takeIf(UInt8(ascii: ","))
        try expect(UInt8(ascii: "]"))
        return rules
    }

    private mutating func range() throws -> (Double, Double) {
        let low = try number(try take())
        guard try peek().kind == .word, try peek().text == Array("..".utf8) else { return (low, low) }
        _ = try take()
        return (low, try number(try take()))
    }

    // MARK: - Values

    private func integer(_ token: DDFToken) throws -> Int64 {
        guard token.kind == .word else { throw error("expected a number", at: token) }
        switch token.string {
        case "NO": return 0
        case "YES": return 1
        case "OFF": return -1
        default:
            guard let value = Self.integerValue(token.text) else {
                throw error("expected a number, found '\(token.string)'", at: token)
            }
            return value
        }
    }

    private func number(_ token: DDFToken) throws -> Double {
        if token.kind == .word, Self.integerValue(token.text) == nil,
           let first = token.text.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+")
               || first == UInt8(ascii: ".") || (first >= 0x30 && first <= 0x39),
           let value = Double(token.string)
        {
            guard value.isFinite else { throw error("SKIPIF bound must be a finite number", at: token) }
            return value
        }
        return Double(try integer(token))
    }

    /// Decimal integer with an optional sign, nil for anything else.
    static func integerValue(_ text: [UInt8]) -> Int64? {
        var index = 0
        var negative = false
        if let first = text.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
            negative = first == UInt8(ascii: "-")
            index = 1
        }
        guard index < text.count else { return nil }
        var value: Int64 = 0
        while index < text.count {
            let digit = text[index] &- 0x30
            guard digit < 10 else { return nil }
            let (times, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(Int64(digit))
            guard !overflow1, !overflow2 else { return nil }
            value = sum
            index += 1
        }
        return negative ? -value : value
    }

    // MARK: - Token plumbing

    private mutating func take() throws -> DDFToken {
        if let token = lookahead {
            lookahead = nil
            return token
        }
        return try lexer.next()
    }

    private mutating func peek() throws -> DDFToken {
        if let token = lookahead { return token }
        let token = try lexer.next()
        lookahead = token
        return token
    }

    private mutating func takeIf(_ punct: UInt8) throws -> Bool {
        guard try peek().isPunct(punct) else { return false }
        _ = try take()
        return true
    }

    private mutating func expect(_ punct: UInt8) throws {
        let token = try take()
        guard token.isPunct(punct) else {
            let found = token.kind == .end ? "end of file" : "'\(token.string)'"
            throw error("expected '\(Character(Unicode.Scalar(punct)))', found \(found)", at: token)
        }
    }

    private func error(_ message: String, at token: DDFToken) -> L2DatError {
        lexer.error(message, line: token.line, column: token.column)
    }
}
