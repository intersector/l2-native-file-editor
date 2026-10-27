import Foundation

/// One row of `<fixtures>/RESULTS.tsv` (columns file, decode, disasm, asm_roundtrip, txt_bytes).
struct CorpusEntry: Sendable {
    let file: String
    /// The original tools' `asm_roundtrip` result: `IDENTICAL`, `DIFF` or `FAIL`.
    let expected: String

    var expectsIdentical: Bool { expected == "IDENTICAL" }

    private static let statuses: Set<String> = ["IDENTICAL", "DIFF", "FAIL"]

    static func load(_ url: URL) throws -> [CorpusEntry] {
        // Split on the byte \n and drop a trailing \r, so CRLF files read like LF files (a String
        // split on "\n" would see one "\r\n" grapheme and no line breaks).
        let lines = try FileIO.read(url).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
            .map { line in String(decoding: line.last == UInt8(ascii: "\r") ? line.dropLast() : line, as: UTF8.self) }
        guard let header = lines.first, header.hasPrefix("file\t") else {
            throw CLIError("\(url.path): expected a header line starting with 'file<TAB>'")
        }
        var entries: [CorpusEntry] = []
        for (index, line) in lines.enumerated().dropFirst() where !line.isEmpty {
            let lineNumber = index + 1
            let cells = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cells.count >= 4, !cells[0].isEmpty else {
                throw CLIError("\(url.path):\(lineNumber): expected at least 4 tab-separated columns")
            }
            let expected = String(cells[3])
            guard statuses.contains(expected) else {
                throw CLIError(
                    "\(url.path):\(lineNumber): unknown asm_roundtrip status '\(expected)' (expected IDENTICAL, DIFF or FAIL)")
            }
            entries.append(CorpusEntry(file: String(cells[0]), expected: expected))
        }
        guard !entries.isEmpty else { throw CLIError("\(url.path): no rows") }
        return entries
    }
}
