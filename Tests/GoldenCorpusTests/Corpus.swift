import Foundation
import L2Dat
import TestSupport

/// Access to `fixtures/high5` (golden corpus produced by the original l2disasm/l2asm 1.4.1).
enum Corpus {
    struct Row {
        let file: String
        let disasm: String
        let roundtrip: String
    }

    static let rows: [Row] = {
        guard let text = try? String(contentsOf: RepoPaths.fixtures.appendingPathComponent("RESULTS.tsv"), encoding: .utf8)
        else { return [] }
        return text.split(separator: "\n").dropFirst().compactMap { line in
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard cells.count >= 4 else { return nil }
            return Row(file: cells[0], disasm: cells[2], roundtrip: cells[3])
        }
    }()

    /// The rows the original tools round-trip byte for byte.
    static let identical: [String] = rows.filter { $0.roundtrip == "IDENTICAL" }.map(\.file)
    /// Rows that disassemble but re-assemble differently with the original tools.
    static let knownDiff: [String] = rows.filter { $0.disasm == "OK" && $0.roundtrip == "DIFF" }.map(\.file)

    static func bytes(_ url: URL) throws -> [UInt8] { [UInt8](try Data(contentsOf: url)) }

    static func dat(_ name: String) throws -> [UInt8] {
        try bytes(RepoPaths.fixtures.appendingPathComponent("dec/dec-\(name).dat"))
    }

    static func txt(_ name: String) throws -> [UInt8] {
        try bytes(RepoPaths.fixtures.appendingPathComponent("txt/\(name).txt"))
    }

    static func exportedDDF(_ name: String) throws -> [UInt8] {
        try bytes(RepoPaths.fixtures.appendingPathComponent("ddf/\(name)-new.ddf"))
    }

    /// The shipped CT2_6 definition the corpus was disassembled with.
    static func schema(_ name: String) throws -> Schema {
        let url = RepoPaths.datDefs.appendingPathComponent("CT2_6/\(name).ddf")
        return try Schema(DDF.parse(try bytes(url), fileName: "\(name).ddf"))
    }

    static func exportedSchema(_ name: String) throws -> Schema {
        try Schema(DDF.parse(try exportedDDF(name), fileName: "\(name)-new.ddf"))
    }
}

/// First differing byte of two buffers with its 1-based line/column in `expected`; nil if equal.
func firstDifference(_ actual: [UInt8], _ expected: [UInt8]) -> (offset: Int, line: Int, column: Int)? {
    let common = min(actual.count, expected.count)
    var offset = 0
    while offset < common, actual[offset] == expected[offset] { offset += 1 }
    if offset == common, actual.count == expected.count { return nil }
    var line = 1, lineStart = 0
    for index in 0..<offset where expected[index] == 0x0A {
        line += 1
        lineStart = index + 1
    }
    return (offset, line, offset - lineStart + 1)
}

/// Human-readable mismatch report: position plus a short excerpt of both sides.
func describeDifference(_ actual: [UInt8], _ expected: [UInt8]) -> String {
    guard let diff = firstDifference(actual, expected) else { return "identical" }
    func excerpt(_ bytes: [UInt8]) -> String {
        let start = max(0, diff.offset - 40), end = min(bytes.count, diff.offset + 40)
        guard start < end else { return "<end>" }
        return String(decoding: bytes[start..<end], as: UTF8.self).debugDescription
    }
    return "first difference at offset \(diff.offset) (line \(diff.line), column \(diff.column)); "
        + "sizes \(actual.count) vs \(expected.count)\n  actual:   \(excerpt(actual))\n  expected: \(excerpt(expected))"
}
