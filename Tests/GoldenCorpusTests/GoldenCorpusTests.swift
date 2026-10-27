import Foundation
import L2Dat
import Testing
import TestSupport

/// Byte-identity against the original tools for every IDENTICAL row of `RESULTS.tsv`.
@Suite(.enabled(if: RepoPaths.fixturesAvailable, "fixtures/high5 enc/dec/txt not present"))
struct GoldenCorpusTests {
    @Test(arguments: Corpus.identical)
    func disasmMatchesGolden(_ name: String) throws {
        let result = try Disassembler.run(dat: try Corpus.dat(name), schema: try Corpus.schema(name))
        let expected = try Corpus.txt(name)
        #expect(result.txt == expected, "\(name): \(describeDifference(result.txt, expected))")
    }

    @Test(arguments: Corpus.identical)
    func asmMatchesGolden(_ name: String) throws {
        let dat = try Assembler.run(txt: try Corpus.txt(name), schema: try Corpus.exportedSchema(name))
        let expected = try Corpus.dat(name)
        #expect(dat == expected, "\(name): \(describeDifference(dat, expected))")
    }

    @Test(arguments: Corpus.identical)
    func fullRoundtripWithOwnSchema(_ name: String) throws {
        let original = try Corpus.dat(name)
        let disasm = try Disassembler.run(dat: original, schema: try Corpus.schema(name))
        let dat = try Assembler.run(txt: disasm.txt, schema: disasm.schema)
        #expect(dat == original, "\(name): \(describeDifference(dat, original))")
    }

    @Test(arguments: Corpus.identical)
    func exportedDDFMatchesGolden(_ name: String) throws {
        let disasm = try Disassembler.run(dat: try Corpus.dat(name), schema: try Corpus.schema(name))
        let exported = DDF.export(disasm.schema)
        let expected = try Corpus.exportedDDF(name)
        #expect(exported == expected, "\(name): \(describeDifference(exported, expected))")
    }

    @Test func npcgrpMismatchThrowsCleanly() throws {
        let error = #expect(throws: L2DatError.self) {
            try Disassembler.run(dat: try Corpus.dat("npcgrp"), schema: try Corpus.schema("npcgrp"))
        }
        print("npcgrp vs CT2_6: \(error.map(String.init(describing:)) ?? "-")")
    }

    /// eula-e, questname-e, ridedata: the original l2asm does not reproduce them. Report, don't assert.
    @Test(arguments: Corpus.knownDiff)
    func knownDiffRowsAreReported(_ name: String) throws {
        let original = try Corpus.dat(name)
        do {
            let disasm = try Disassembler.run(dat: original, schema: try Corpus.schema(name))
            let golden = try Corpus.txt(name)
            let dat = try Assembler.run(txt: disasm.txt, schema: disasm.schema)
            print("\(name): disasm vs golden txt: \(describeDifference(disasm.txt, golden)); "
                + "own round trip: \(describeDifference(dat, original))")
        } catch {
            print("\(name): \(error)")
        }
    }

    /// Release-mode performance guard (spec target < 1.5 s each on armorgrp).
    @Test func armorgrpTiming() throws {
        let dat = try Corpus.dat("armorgrp")
        let schema = try Corpus.schema("armorgrp")
        let clock = ContinuousClock()
        var disasm: DisasmResult?
        let disasmTime = try clock.measure { disasm = try Disassembler.run(dat: dat, schema: schema) }
        let result = try #require(disasm)
        var assembled: [UInt8] = []
        let asmTime = try clock.measure { assembled = try Assembler.run(txt: result.txt, schema: result.schema) }
        #expect(assembled == dat)
        print("armorgrp timing: disasm \(disasmTime), asm \(asmTime) (\(dat.count) dat bytes, \(result.txt.count) txt bytes)")
        #if !DEBUG
        #expect(disasmTime < .milliseconds(1500))
        #expect(asmTime < .milliseconds(1500))
        #endif
    }
}
