import L2Dat
import Testing

/// Regressions for malformed or adversarial input: wrong bytes, traps and runaway output.
struct RobustnessTests {
    // MARK: - ASCF wide flag

    @Test func emptyWideAscfKeepsTheWideFlag() throws {
        let ddf = "{ ASCF s; }"
        let wide = Fixtures.dat(records: 1, [0x80])
        #expect(try Fixtures.disasm(ddf, wide) == "s\nu,\n")
        #expect(try Fixtures.asm(ddf, "s\nu,\n") == wide)
        let narrow = Fixtures.dat(records: 1, [0x00])
        #expect(try Fixtures.disasm(ddf, narrow) == "s\na,\n")
        #expect(try Fixtures.asm(ddf, "s\na,\n") == narrow)
    }

    // MARK: - Non-finite SKIPIF bounds

    @Test(arguments: ["-nan", "+nan", "nan", "-inf", "+inf", "inf", "1e999"])
    func nonFiniteSkipIfBoundThrows(_ bound: String) throws {
        let ddf = "RECCNT = OFF; { UINT n; UINT t[n]; SKIPIF = [(0, \(bound))]; }"
        let error = #expect(throws: L2DatError.self) { try Fixtures.schema(ddf) }
        guard case let .ddfSyntax(_, line, column, _)? = error else {
            Issue.record("expected ddfSyntax, got \(String(describing: error))")
            return
        }
        #expect(line == 1 && column > 1)
        let range = "RECCNT = OFF; { UINT n; UINT t[n]; SKIPIF = [(0, 1 .. \(bound))]; }"
        #expect(throws: L2DatError.self) { try Fixtures.schema(range) }
    }

    @Test func exportRendersNonFiniteSkipIfBoundsWithoutTrapping() throws {
        var document = try DDF.parse(Array("{ UINT t[2]; SKIPIF = [(0, 1)]; }".utf8), fileName: "t.ddf")
        document.fields[0].skipIf = [
            SkipIfRule(indexLow: 0, indexHigh: 0, valueLow: .nan, valueHigh: .infinity),
            SkipIfRule(indexLow: 1, indexHigh: 1, valueLow: -.infinity, valueHigh: 1e300),
        ]
        let text = String(decoding: DDF.export(try Schema(document)), as: UTF8.self)
        #expect(text.contains("nan"))
        #expect(text.contains("-inf"))
    }

    // MARK: - Output size cap

    @Test func wideShapeThrowsTypedErrorInsteadOfAllocating() throws {
        // One record with 300000 elements raises SOFT for every later (empty) record: 8000 records
        // x 300000 separators is ~2.4 GB of output from a ~340 KB dat.
        let ddf = "{ UINT n; UCHAR t[n]; }"
        var body = Fixtures.le32(300_000) + [UInt8](repeating: 1, count: 300_000)
        for _ in 0..<7999 { body += Fixtures.le32(0) }
        let dat = Fixtures.dat(records: 8000, body)
        let error = #expect(throws: L2DatError.self) { try Fixtures.disasm(ddf, dat) }
        guard case let .outputTooLarge(field, soft, records, estimatedBytes, limit)? = error else {
            Issue.record("expected outputTooLarge, got \(String(describing: error))")
            return
        }
        #expect(field == "t" && soft == 300_000 && records == 8000)
        #expect(estimatedBytes == 8000 * 300_000 && limit == 1 << 30)
        #expect(error?.description.contains("'t'") == true)
    }

    @Test func moderateWideShapeStillDisassembles() throws {
        let ddf = "{ UINT n; UCHAR t[n]; }"
        var body = Fixtures.le32(100) + [UInt8](repeating: 1, count: 100)
        for _ in 0..<99 { body += Fixtures.le32(0) }
        let txt = try Fixtures.disasm(ddf, Fixtures.dat(records: 100, body))
        #expect(txt.split(separator: "\n").count == 101)
    }
}
