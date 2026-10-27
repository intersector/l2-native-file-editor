import L2Dat
import Testing

/// FLOAT text (`%.8f`, raw bits through NaN) and integer types.
struct NumberTests {
    static let floats: [(bits: UInt32, text: String)] = [
        (0x3F8A_3D71, "1.08000004"),
        (0x8000_0000, "-0.00000000"),
        (0x0000_0000, "0.00000000"),
        (0x3F73_3333, "0.94999999"),
        (0x4130_0000, "11.00000000"),
        (0xC2C8_0000, "-100.00000000"),
        (0xFFFF_4000, "NaN(0xFFFF4000)"),
        (0x7FC0_0000, "NaN(0x7FC00000)"),
    ]

    @Test(arguments: floats)
    func floatText(_ entry: (bits: UInt32, text: String)) throws {
        let dat = Fixtures.dat(records: 1, Fixtures.le32(entry.bits))
        #expect(try Fixtures.disasm("{ FLOAT f; }", dat) == "f\n\(entry.text)\n")
        #expect(try Fixtures.asm("{ FLOAT f; }", "f\n\(entry.text)\n") == dat)
    }

    @Test func scientificFormat() throws {
        let dat = Fixtures.dat(records: 1, Fixtures.le32(0x3F8A_3D71))
        let txt = try Fixtures.disasm("{ FLOAT f; }", dat, options: DisasmOptions(floatFormat: .scientific))
        #expect(txt == "f\n1.08000004e+00\n")
        #expect(try Fixtures.asm("{ FLOAT f; }", txt) == dat)
    }

    @Test func garbageFloatThrows() {
        #expect(throws: L2DatError.self) { try Fixtures.asm("{ FLOAT f; }", "f\n1.0x\n") }
    }

    @Test func integerTypesAndHex() throws {
        let ddf = "{ UINT a; INT b; UWORD c; WORD d; UCHAR e; CHAR f; HEX g; CHEX h; }"
        let body: [UInt8] = Fixtures.le32(4_000_000_000) + Fixtures.le32(UInt32(bitPattern: -5))
            + [0xFE, 0xFF] + [0xFE, 0xFF] + [0xFF] + [0xFF] + Fixtures.le32(0x05BE_0954) + [0x0A]
        let dat = Fixtures.dat(records: 1, body)
        let txt = "a\tb\tc\td\te\tf\tg\th\n4000000000\t-5\t65534\t-2\t255\t-1\t5BE0954\tA\n"
        #expect(try Fixtures.disasm(ddf, dat) == txt)
        #expect(try Fixtures.asm(ddf, txt) == dat)
    }

    @Test func integersTruncateLikeACast() throws {
        // -1 into UINT, 256 into UCHAR, 70000 into UWORD.
        let dat = try Fixtures.asm("{ UINT a; UCHAR b; UWORD c; }", "a\tb\tc\n-1\t256\t70000\n")
        #expect(dat == Fixtures.dat(records: 1, [0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x70, 0x11]))
    }

    @Test func emptyIntegerIsZeroWithWarning() throws {
        let result = try Assembler.assemble(txt: Array("a\tb\n\t7\n".utf8), schema: try Fixtures.schema("{ UINT a; UINT b; }"))
        #expect(result.dat == Fixtures.dat(records: 1, Fixtures.le32(0) + Fixtures.le32(7)))
        #expect(result.warnings.count == 1)
    }

    @Test func nonNumericIntegerThrows() {
        #expect(throws: L2DatError.self) { try Fixtures.asm("{ UINT a; }", "a\nx1\n") }
    }
}
