import L2Dat
import Testing
import TestSupport

/// Truncated and corrupted inputs must throw `L2DatError` (or succeed), never trap or hang.
@Suite(.enabled(if: RepoPaths.fixturesAvailable, "fixtures/high5 enc/dec/txt not present"))
struct MalformedInputTests {
    static let files = ["logongrp", "chargrp", "recipe-c", "mantleexception", "hennagrp-e"]

    /// Deterministic generator so failures reproduce.
    struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    @Test(arguments: files)
    func corruptedDatNeverTraps(_ name: String) throws {
        let original = try Corpus.dat(name)
        let schema = try Corpus.schema(name)
        var random = Lcg(state: UInt64(original.count))
        for round in 0..<120 {
            var dat = original
            if round % 3 == 0 {
                dat.removeLast(random.next(dat.count))
            } else {
                for _ in 0..<(1 + random.next(8)) { dat[random.next(dat.count)] = UInt8(random.next(256)) }
            }
            do {
                _ = try Disassembler.run(dat: dat, schema: schema)
            } catch is L2DatError {
            }
        }
    }

    @Test(arguments: files)
    func corruptedTxtNeverTraps(_ name: String) throws {
        let original = try Corpus.txt(name)
        let schema = try Corpus.exportedSchema(name)
        var random = Lcg(state: UInt64(original.count))
        let alphabet = Array("\t\n\\,-0123456789aux\u{7F}".utf8) + [0xC3, 0xFF, 0x00]
        for round in 0..<120 {
            var txt = original
            if round % 3 == 0 {
                txt.removeLast(random.next(txt.count))
            } else {
                for _ in 0..<(1 + random.next(8)) {
                    txt[random.next(txt.count)] = alphabet[random.next(alphabet.count)]
                }
            }
            do {
                _ = try Assembler.run(txt: txt, schema: schema)
            } catch is L2DatError {
            }
        }
    }
}
