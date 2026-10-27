import L2Dat
import Testing

/// CNTR / compact index (as the original l2disasm), via a one-column `CNTR` schema.
struct CompactIndexTests {
    static let ddf = "{ CNTR c; }"

    static let table: [(value: UInt32, bytes: [UInt8])] = [
        (0, [0x00]),
        (1, [0x01]),
        (12, [0x0C]),
        (63, [0x3F]),
        (64, [0x40, 0x01]),
        (169, [0x69, 0x02]),
        (0x3FFF, [0x7F, 0xFF, 0x01]),
        (0x1F_FFFF, [0x7F, 0xFF, 0xFF, 0x01]),
        (0xFFF_FFFF, [0x7F, 0xFF, 0xFF, 0xFF, 0x01]),
        (0xFFFF_FFFF, [0x7F, 0xFF, 0xFF, 0xFF, 0x1F]),
    ]

    @Test(arguments: table)
    func readsAndWritesMinimalBytes(_ entry: (value: UInt32, bytes: [UInt8])) throws {
        let dat = Fixtures.dat(records: 1, entry.bytes)
        #expect(try Fixtures.disasm(Self.ddf, dat) == "c\n\(entry.value)\n")
        #expect(try Fixtures.asm(Self.ddf, "c\n\(entry.value)\n") == dat)
    }

    @Test func identityOverManyValues() throws {
        var values: [UInt32] = Array(0..<4100)
        var power: UInt32 = 1
        while power < 0x8000_0000 {
            power <<= 1
            values += [power - 1, power, power + 1]
        }
        let txt = "c\n" + values.map(String.init).joined(separator: "\n") + "\n"
        let dat = try Fixtures.asm(Self.ddf, txt)
        #expect(try Fixtures.disasm(Self.ddf, dat) == txt)
    }

    @Test func signBitIsTheWideFlag() throws {
        // ASCF length -12 (UTF-16, 12 units) is a single 0x8C byte.
        let text = "hello world\0"
        let dat = Fixtures.dat(records: 1, [0x8C] + Fixtures.utf16(text))
        #expect(try Fixtures.disasm("{ ASCF s; }", dat) == "s\nu,hello world\\0\n")
        // 64 wide units: 0xC0 0x01.
        let long = String(repeating: "x", count: 64)
        let longDat = Fixtures.dat(records: 1, [0xC0, 0x01] + Fixtures.utf16(long))
        #expect(try Fixtures.asm("{ ASCF s; }", "s\nu,\(long)\n") == longDat)
    }

    @Test func acceptsNonMinimalEncodingOnRead() throws {
        #expect(try Fixtures.disasm(Self.ddf, Fixtures.dat(records: 1, [0x40, 0x00])) == "c\n0\n")
    }

    @Test func truncatedIndexThrows() throws {
        let dat = Fixtures.le32(1) + [0x7F, 0xFF]
        #expect(throws: L2DatError.self) { try Fixtures.disasm(Self.ddf, dat) }
    }

    @Test func counterDrivesTableLength() throws {
        let ddf = "{ CNTR n; UCHAR b[n]; SOFT = 2; }"
        let dat = Fixtures.dat(records: 2, [0x02, 7, 8, 0x01, 9])
        let txt = "n\tb[0]\tb[1]\n2\t7\t8\n1\t9\t\n"
        #expect(try Fixtures.disasm(ddf, dat) == txt)
        #expect(try Fixtures.asm(ddf, txt) == dat)
    }
}
