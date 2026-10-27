import L2Dat
import Testing

/// Column naming per field kind, observed through the disassembler's header line.
struct ColumnPlanTests {
    /// Header of a zero-record file for `ddf` (soft limits come from the DDF or default to 1).
    func header(_ ddf: String) throws -> [String] {
        let txt = try Fixtures.disasm(ddf, Fixtures.dat(records: 0, []))
        return txt.dropLast().split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
    }

    @Test func scalarsAndTables() throws {
        #expect(try header("{ UINT a; INT t[3]; UINT n; UNICODE one[n]; UNICODE many[n]; SOFT = 3; FILLER void_1{360}; }") == [
            "a", "t[0]", "t[1]", "t[2]", "n", "one", "many[0]", "many[1]", "many[2]", "void_1{360}",
        ])
    }

    @Test func mtx() throws {
        #expect(try header("{ MTX N; SOFTM = 1; SOFTT = 2; }") == ["N_cntm", "N_m[0]", "N_cntt", "N_t[0]", "N_t[1]"])
    }

    @Test func mtx2() throws {
        #expect(try header("{ MTX2 N; SOFTM = 2; }") == [
            "N_cntm", "N_m[0]", "N_m[0]_id", "N_m[0]_cnt", "N_m[1]", "N_m[1]_id", "N_m[1]_cnt", "N_cntt", "N_t[0]",
        ])
    }

    @Test func mtx3() throws {
        #expect(try header("{ MTX3 N; SOFTM = 2; SOFTT = 1; }") == [
            "N_cntm", "N_mU[0]", "N_mB[0][1]", "N_mB[0][2]", "N_mU[1]", "N_mB[1][1]", "N_mB[1][2]",
            "N_cntt", "N_t[0]", "N_tE",
        ])
    }

    @Test func mat() throws {
        #expect(try header("{ MAT N; SOFTM = 2; }") == ["N_cnt", "N_m[0]_id", "N_m[0]_cnt", "N_m[1]_id", "N_m[1]_cnt"])
        #expect(try header("{ MAT2 N; }") == ["N_cnt", "N_extra", "N_m[0]_id", "N_m[0]_cnt"])
    }

    @Test func countersHiddenWhenCountOutIsNo() throws {
        #expect(try header("MTXCNT_OUT = NO; MATCNT_OUT = NO; { MTX A; MAT2 B; }") == ["A_m[0]", "A_t[0]", "B_extra", "B_m[0]_id", "B_m[0]_cnt"])
    }

    @Test func ordReordersAndHides() throws {
        let ddf = "{ UINT a; UINT b; ORD = 2; UINT c; ORD = OFF; UINT d; ORD = 1; }"
        #expect(try header(ddf) == ["d", "b", "a"])
        #expect(try header("ORD_IGNORE = YES; " + ddf) == ["a", "b", "c", "d"])
    }

    @Test func mtxRoundTripPlacesEveryPart() throws {
        let ddf = "{ MTX3 N; SOFTM = 2; SOFTT = 2; }"
        let body: [UInt8] = Fixtures.le32(1) + [2, 0, 0, 0] + Fixtures.utf16("m") + [7, 255]
            + Fixtures.le32(1) + [0, 0, 0, 0] + [2, 0, 0, 0] + Fixtures.utf16("e")
        let dat = Fixtures.dat(records: 1, body)
        let txt = try Fixtures.disasm(ddf, dat)
        #expect(txt.split(separator: "\n").last == "1\tm\t7\t255\t\t\t\t1\t\t\te")
        #expect(try Fixtures.asm(ddf, txt) == dat)
    }

    @Test func softLimitsGrowToTheData() throws {
        let ddf = "{ UINT n; UCHAR b[n]; SOFT = 1; }"
        let dat = Fixtures.dat(records: 2, Fixtures.le32(1) + [5] + Fixtures.le32(3) + [1, 2, 3])
        let result = try Disassembler.run(dat: dat, schema: try Fixtures.schema(ddf))
        #expect(result.schema.fields[1].soft == 3)
        #expect(String(decoding: DDF.export(result.schema), as: UTF8.self).contains("\t\tSOFT = 3;\r\n"))
    }
}
