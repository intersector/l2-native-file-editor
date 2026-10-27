import L2Dat
import Testing

/// ASCF, UNICODE and txt escapes.
struct StringTests {
    // MARK: ASCF

    @Test func ascfLatin1WithTerminator() throws {
        // "café\0": 5 bytes, 0xE9 is é in ISO-8859-1 and becomes a 2-byte UTF-8 sequence.
        let dat = Fixtures.dat(records: 1, [0x05, 0x63, 0x61, 0x66, 0xE9, 0x00])
        let txt = "s\na,café\\0\n"
        #expect(try Fixtures.disasm("{ ASCF s; }", dat) == txt)
        #expect(try Fixtures.asm("{ ASCF s; }", txt) == dat)
    }

    @Test func ascfEmptyIsLengthZero() throws {
        let dat = Fixtures.dat(records: 1, [0x00])
        #expect(try Fixtures.disasm("{ ASCF s; }", dat) == "s\na,\n")
        #expect(try Fixtures.asm("{ ASCF s; }", "s\na,\n") == dat)
        // A wide empty cell keeps the wide flag (0x80), as the original l2asm writes it.
        #expect(try Fixtures.asm("{ ASCF s; }", "s\nu,\n") == Fixtures.dat(records: 1, [0x80]))
    }

    @Test func ascfWide() throws {
        let dat = Fixtures.dat(records: 1, [0x83] + Fixtures.utf16("Ωé\0"))
        #expect(try Fixtures.disasm("{ ASCF s; }", dat) == "s\nu,Ωé\\0\n")
        #expect(try Fixtures.asm("{ ASCF s; }", "s\nu,Ωé\\0\n") == dat)
    }

    @Test func ascfForceAsciiHintAndForceEightBit() throws {
        let wide = Fixtures.dat(records: 1, [0x82] + Fixtures.utf16("é\0"))
        #expect(try Fixtures.disasm("{ ASCF s; }", wide, options: DisasmOptions(forceAsciiHint: true)) == "s\na,é\\0\n")
        let narrow = Fixtures.dat(records: 1, [0x02, 0xE9, 0x00])
        #expect(try Fixtures.asm("{ ASCF s; }", "s\nu,é\\0\n", options: AsmOptions(forceEightBit: true)) == narrow)
    }

    @Test func ascfUTF8CharsetPassesBytesThrough() throws {
        let dat = Fixtures.dat(records: 1, [0x03, 0xC3, 0xA9, 0x00])
        #expect(try Fixtures.disasm("{ ASCF s; }", dat, options: DisasmOptions(charset: .utf8)) == "s\na,é\\0\n")
        #expect(try Fixtures.asm("{ ASCF s; }", "s\na,é\\0\n", options: AsmOptions(charset: .utf8)) == dat)
    }

    @Test func ascfRejectsWideCharactersInEightBitStrings() {
        #expect(throws: L2DatError.self) { try Fixtures.asm("{ ASCF s; }", "s\na,Ω\n") }
    }

    @Test func ascfNeedsAHint() {
        #expect(throws: L2DatError.self) { try Fixtures.asm("{ ASCF s; }", "s\nplain\n") }
    }

    @Test func ascfLengthLimit() {
        // 0x18001 bytes declared: rejected before reading.
        let dat = Fixtures.le32(1) + [0x41, 0x80, 0x0C]
        #expect(throws: L2DatError.self) { try Fixtures.disasm("{ ASCF s; }", dat) }
    }

    // MARK: UNICODE

    @Test func unicodeByteLengthWithoutTerminator() throws {
        let dat = Fixtures.dat(records: 1, [0x18, 0, 0, 0] + Fixtures.utf16("Wooden Arrow"))
        #expect(try Fixtures.disasm("{ UNICODE s; }", dat) == "s\nWooden Arrow\n")
        #expect(try Fixtures.asm("{ UNICODE s; }", "s\nWooden Arrow\n") == dat)
    }

    @Test func unicodeSurrogatePairs() throws {
        let dat = Fixtures.dat(records: 1, [0x04, 0, 0, 0, 0x3D, 0xD8, 0x00, 0xDE])
        #expect(try Fixtures.disasm("{ UNICODE s; }", dat) == "s\n😀\n")
        #expect(try Fixtures.asm("{ UNICODE s; }", "s\n😀\n") == dat)
    }

    @Test func unicodeLoneSurrogateThrows() {
        let dat = Fixtures.dat(records: 1, [0x02, 0, 0, 0, 0x3D, 0xD8])
        #expect(throws: L2DatError.self) { try Fixtures.disasm("{ UNICODE s; }", dat) }
    }

    @Test func unicodeOddLengthThrows() {
        let dat = Fixtures.dat(records: 1, [0x03, 0, 0, 0, 0x41, 0x00, 0x42])
        #expect(throws: L2DatError.self) { try Fixtures.disasm("{ UNICODE s; }", dat) }
    }

    @Test func invalidUTF8InTxtThrowsWithPosition() throws {
        let txt: [UInt8] = Array("s\nab".utf8) + [0xFF] + [0x0A]
        let error = #expect(throws: L2DatError.self) {
            try Assembler.run(txt: txt, schema: try Fixtures.schema("{ UNICODE s; }"))
        }
        #expect(error == .txtFormat(line: 2, column: 3, field: "s", message: "invalid UTF-8"))
    }

    // MARK: Escapes

    @Test func escapesRoundTrip() throws {
        let raw = "a\\b\tc\rd\ne\0"
        let escaped = "a\\\\b\\tc\\rd\\ne\\0"
        let units = Fixtures.utf16(raw)
        let dat = Fixtures.dat(records: 1, Fixtures.le32(UInt32(units.count)) + units)
        #expect(try Fixtures.disasm("{ UNICODE s; }", dat) == "s\n\(escaped)\n")
        #expect(try Fixtures.asm("{ UNICODE s; }", "s\n\(escaped)\n") == dat)
    }

    @Test func otherCharactersAreNotEscaped() throws {
        let text = "\"quoted\" 'x' %d {}"
        let units = Fixtures.utf16(text)
        let dat = Fixtures.dat(records: 1, Fixtures.le32(UInt32(units.count)) + units)
        #expect(try Fixtures.disasm("{ UNICODE s; }", dat) == "s\n\(text)\n")
    }

    @Test func unknownEscapeThrowsWithPosition() throws {
        let error = #expect(throws: L2DatError.self) {
            try Fixtures.asm("{ UINT a; UNICODE s; }", "a\ts\n1\tok\\x\n")
        }
        #expect(error == .txtFormat(line: 2, column: 5, field: "s", message: "unknown escape '\\x'"))
    }
}
