import Foundation
import L2Dat
import Testing
import TestSupport

/// DDF grammar and the quirks found across the shipped DAT_defs.
struct DDFParserTests {
    func parse(_ text: String) throws -> DDFDocument {
        try DDF.parse(Array(text.utf8), fileName: "q.ddf")
    }

    @Test func defaultsAndControlSpellings() throws {
        let doc = try parse("FS=\"\\t\";\r\nRECCNT =OFF;\r\nHEADER = 0;\r\nMTXCNT_OUT = YES;\r\nMAGIC = 0;\r\nORD_IGNORE = 1;\r\n{\r\n\tUINT id;\r\n}\r\n")
        #expect(doc.controls == DDFControls(fs: [0x09], recCnt: -1, ordIgnore: true, header: false))
        #expect(doc.fields == [DDFField(type: .uint, ident: "id", line: 8)])
    }

    @Test func reccntMinusOneIsOffAndCountsAreKept() throws {
        #expect(try parse("RECCNT=-1; { UINT a; }").controls.recCnt == -1)
        #expect(try parse("RECCNT = 17; { UINT a; }").controls.recCnt == 17)
    }

    @Test func otherSeparators() throws {
        #expect(try parse("FS = \"|\"; { UINT a; }").controls.fs == Array("|".utf8))
    }

    @Test func commentsOfAllThreeKinds() throws {
        let doc = try parse("""
            // line comment
            # shell comment
            /* block
               comment */ FS = "\\t";
            {
            \tUINT a; // trailing
            /*\tUINT b; */
            #\tUINT c;
            }
            /* trailing text after the body is never tokenised: ( ] ' */ stray ][
            """)
        #expect(doc.fields.map(\.ident) == ["a"])
    }

    @Test func tablesFillerAndOddIdents() throws {
        let doc = try parse("{ UINT n; UNICODE s[n]; INT t[3]; FILLER void_1{360}; UINT walkanimframe?; \tUINT x.y; }")
        #expect(doc.fields.map(\.table) == [.none, .dynamic("n"), .fixed(3), .filler(360), .none, .none])
        #expect(doc.fields[4].ident == "walkanimframe?")
    }

    @Test func propertiesOnTheSameLineAndMultiConditionEnbby() throws {
        let doc = try parse("{ UINT k; UINT r;ENBBY = [(k:-2,6)];ENBBY = [(k,1), (r:4, 4)]; ORD=OFF; SOFT = 3; }")
        let field = doc.fields[1]
        #expect(field.enbby == [
            [EnbbyCondition(ref: "k", mask: -2, value: 6)],
            [EnbbyCondition(ref: "k", value: 1), EnbbyCondition(ref: "r", mask: 4, value: 4)],
        ])
        #expect(field.ord == -1)
        #expect(field.soft == 3)
    }

    @Test func ordValues() throws {
        let doc = try parse("{ UINT a; ORD = -1; UINT b; ORD=2; UINT c; }")
        #expect(doc.fields.map(\.ord) == [-1, 2, nil])
    }

    @Test func compoundSoftLimits() throws {
        let doc = try parse("{ MTX m; SOFTT = 4; SOFTM = 2; MAT2 x; SOFTM = 3; }")
        #expect(doc.fields[0].softM == 2 && doc.fields[0].softT == 4)
        #expect(doc.fields[1].softM == 3)
    }

    @Test func skipIfRanges() throws {
        let doc = try parse("{ UINT v[10]; SKIPIF = [(1, 3), (4 .. 8, -4 .. -2)]; }")
        #expect(doc.fields[0].skipIf == [
            SkipIfRule(indexLow: 1, indexHigh: 1, valueLow: 3, valueHigh: 3),
            SkipIfRule(indexLow: 4, indexHigh: 8, valueLow: -4, valueHigh: -2),
        ])
    }

    @Test func syntaxErrorsCarryLineAndColumn() throws {
        let error = #expect(throws: L2DatError.self) { try parse("{\n  UINT a;\n  BOGUS b;\n}") }
        #expect(error == .ddfSyntax(file: "q.ddf", line: 3, column: 3, message: "unknown field type 'BOGUS'"))
        #expect(throws: L2DatError.self) { try parse("{ UINT a; ") }
        #expect(throws: L2DatError.self) { try parse("{ UINT a }") }
        #expect(throws: L2DatError.self) { try parse("/* never closed { UINT a; }") }
        #expect(throws: L2DatError.self) { try parse("{ SOFT = 1; UINT a; }") }
    }

    @Test func duplicateIdentsResolveBackwards() throws {
        let schema = try Fixtures.schema("{ UINT n; UCHAR b[n]; SOFT = 1; UINT n; UCHAR b[n]; SOFT = 1; }")
        #expect(schema.fields[1].count == .dynamic(0))
        #expect(schema.fields[3].count == .dynamic(2))
    }

    @Test func unresolvableReferencesThrow() {
        #expect(throws: L2DatError.self) { try Fixtures.schema("{ UCHAR b[n]; UINT n; }") }
        #expect(throws: L2DatError.self) { try Fixtures.schema("{ UNICODE n; UCHAR b[n]; }") }
        #expect(throws: L2DatError.self) { try Fixtures.schema("{ UINT a; ENBBY = [(zz, 1)]; }") }
    }

    /// Every shipped definition (4069 files, 56 chronicles) parses and resolves.
    @Test func allShippedDefinitionsParse() throws {
        let root = RepoPaths.datDefs
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var parsed = 0
        var failures: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "ddf" {
            let name = url.path.replacingOccurrences(of: root.path + "/", with: "")
            do {
                _ = try Schema(DDF.parse([UInt8](try Data(contentsOf: url)), fileName: name))
                parsed += 1
            } catch {
                failures.append("\(error)")
            }
        }
        #expect(failures.isEmpty, "\(failures.count) failures:\n\(failures.prefix(20).joined(separator: "\n"))")
        #expect(parsed == 4069)
    }
}
