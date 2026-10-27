import L2Dat
import Testing

/// ENBBY, RECCNT, FILLER, tails and malformed-input errors.
struct RecordLayoutTests {
    @Test func enbbyMaskAndOr() throws {
        // x enabled when (k & -2) == 2  OR  k == 9.
        let ddf = "{ UINT k; UCHAR x; ENBBY = [(k:-2,2)]; ENBBY = [(k,9)]; UCHAR y; }"
        let body: [UInt8] = Fixtures.le32(3) + [1, 2] + Fixtures.le32(9) + [3, 4] + Fixtures.le32(4) + [5]
        let dat = Fixtures.dat(records: 3, body)
        let txt = "k\tx\ty\n3\t1\t2\n9\t3\t4\n4\t\t5\n"
        #expect(try Fixtures.disasm(ddf, dat) == txt)
        #expect(try Fixtures.asm(ddf, txt) == dat)
    }

    @Test func enbbyAndConditionsAndTableReference() throws {
        // Element 0 of a table is the referenced value.
        let ddf = "{ UCHAR t[2]; UCHAR z; UCHAR x; ENBBY = [(t,1),(z:1,1)]; }"
        let dat = Fixtures.dat(records: 2, [1, 0, 3, 8] + [1, 0, 2])
        #expect(try Fixtures.disasm(ddf, dat) == "t[0]\tt[1]\tz\tx\n1\t0\t3\t8\n1\t0\t2\t\n")
    }

    @Test func fixedRecordCountHasNoCountField() throws {
        let ddf = "RECCNT = 2; { UCHAR a; }"
        let dat: [UInt8] = [7, 8] + Fixtures.tail
        #expect(try Fixtures.disasm(ddf, dat) == "a\n7\n8\n")
        #expect(try Fixtures.asm(ddf, "a\n7\n8\n") == dat)
        let result = try Assembler.assemble(txt: Array("a\n7\n".utf8), schema: try Fixtures.schema(ddf))
        #expect(result.warnings.count == 1)
    }

    @Test func fillerAndMagic() throws {
        let ddf = "MAGIC = 2; { FILLER pad{3}; UCHAR a; }"
        let dat: [UInt8] = Fixtures.le32(1) + [0, 0, 0, 5] + [0, 0, 0, 0, 0, 0, 0, 0] + Fixtures.tail
        #expect(try Fixtures.disasm(ddf, dat) == "pad{3}\ta\n0\t5\n")
        #expect(try Fixtures.asm(ddf, "pad{3}\ta\n0\t5\n") == dat)
    }

    @Test func noHeaderOptionAndCRLFInput() throws {
        let ddf = "{ UCHAR a; UCHAR b; }"
        let dat = Fixtures.dat(records: 1, [1, 2])
        #expect(try Fixtures.disasm(ddf, dat, options: DisasmOptions(noHeader: true)) == "1\t2\n")
        #expect(try Fixtures.asm(ddf, "a\tb\r\n1\t2\r\n") == dat)
        #expect(try Fixtures.asm(ddf, "1\t2", options: AsmOptions(noHeader: true)) == dat)
    }

    @Test func missingTrailingCellsReadAsEmpty() throws {
        let ddf = "{ UINT n; UCHAR b[n]; SOFT = 3; }"
        #expect(try Fixtures.asm(ddf, "n\tb[0]\tb[1]\tb[2]\n1\t4\n") == Fixtures.dat(records: 1, Fixtures.le32(1) + [4]))
    }

    @Test func truncatedRecordThrowsWithContext() throws {
        let dat = Fixtures.le32(2) + [1, 0, 0, 0, 2, 0]
        let error = #expect(throws: L2DatError.self) { try Fixtures.disasm("{ UINT a; }", dat) }
        #expect(error == .datFormat(record: 1, field: "a", offset: 8, message: "unexpected end of data (need 4 bytes, 2 left)"))
    }

    @Test func trailingGarbageThrows() {
        let dat = Fixtures.le32(1) + [1, 2, 3]
        #expect(throws: L2DatError.self) { try Fixtures.disasm("{ UCHAR a; }", dat) }
    }

    @Test func counterAboveSoftLimitThrows() {
        let ddf = "{ UINT n; UCHAR b[n]; SOFT = 1; }"
        #expect(throws: L2DatError.self) { try Fixtures.asm(ddf, "n\tb\n2\t1\n") }
    }

    @Test func assemblyNeedsSoftLimits() {
        let error = #expect(throws: L2DatError.self) { try Fixtures.asm("{ UINT n; UCHAR b[n]; }", "n\tb\n0\t\n") }
        #expect(error == .ddfSchema(file: "test.ddf", field: "b", message: "has no soft limit (SOFT)"))
    }

    @Test func tooManyCellsThrow() {
        #expect(throws: L2DatError.self) { try Fixtures.asm("{ UCHAR a; }", "a\n1\t2\n") }
    }

    @Test func legacyTransliterationIsUnsupported() {
        #expect(throws: L2DatError.unsupported("legacy transliteration (-l) is not available in this version")) {
            try Fixtures.disasm("{ UCHAR a; }", Fixtures.dat(records: 0, []), options: DisasmOptions(legacyTransliteration: true))
        }
        #expect(throws: L2DatError.self) {
            try Fixtures.asm("{ UCHAR a; }", "a\n", options: AsmOptions(legacyTransliteration: true))
        }
    }

    @Test func skipIfPrintsEmptyCells() throws {
        let ddf = "{ UCHAR v[3]; SKIPIF = [(1, 3), (2 .. 2, 0 .. 9)]; }"
        #expect(try Fixtures.disasm(ddf, Fixtures.dat(records: 1, [3, 3, 4])) == "v[0]\tv[1]\tv[2]\n3\t\t\n")
    }

    @Test func exportFormat() throws {
        let schema = try Fixtures.schema("""
            FS="\\t"; RECCNT = 8; HEADER = 1; ORD_IGNORE = 0;
            { UINT k; // comment
              UNICODE s[k]; SOFT = 2;
              MTX m; SOFTM = 1; SOFTT = 3;
              MAT2 x; SOFTM = 4;
              FILLER f{9};
              INT  w; ENBBY = [(k,2)]; }
            """)
        let expected = [
            "FS = \"\\t\";", "RECCNT = 8;", "HEADER = YES;", "MTXCNT_OUT = YES;", "MATCNT_OUT = YES;", "MAGIC = 0;",
            "ORD_IGNORE = NO;", "", "{", "\tUINT k;", "\tUNICODE s[k];", "\t\tSOFT = 2;", "\tMTX m;", "\t\tSOFTT = 3;",
            "\t\tSOFTM = 1;", "\tMAT2 x;", "\t\tSOFTM = 4;", "\tFILLER f{9};", "\tINT w;", "\t\tENBBY = [(k: -1, 2)];", "}",
        ].map { $0 + "\r\n" }.joined()
        #expect(String(decoding: DDF.export(schema), as: UTF8.self) == expected)
    }
}
