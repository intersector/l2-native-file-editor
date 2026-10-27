/// The four checks of one corpus row.
struct CorpusOutcome: Sendable {
    let entry: CorpusEntry
    /// decode(enc) vs dec.
    let decode: CorpusCheck
    /// disasm(dec, <ddf dir>/<name>.ddf) vs txt.
    let disasm: CorpusCheck
    /// asm(txt, ddf/<name>-new.ddf) vs dec.
    let asm: CorpusCheck
    /// Exported DDF vs ddf/<name>-new.ddf.
    let export: CorpusCheck
    let txtBytes: Int

    var checks: [(name: String, check: CorpusCheck)] {
        [("decode", decode), ("disasm", disasm), ("asm", asm), ("export", export)]
    }

    var allIdentical: Bool { checks.allSatisfy(\.check.isIdentical) }

    /// PASS / FAIL for rows the original tools round-trip; KNOWN (reported only) for the others.
    var status: String {
        guard entry.expectsIdentical else { return "KNOWN" }
        return allIdentical ? "PASS" : "FAIL"
    }

    var row: String {
        [entry.file, decode.cell, disasm.cell, asm.cell, export.cell, String(txtBytes), entry.expected, status]
            .joined(separator: "\t")
    }

    static let header = "file\tdecode\tdisasm\tasm_roundtrip\texport\ttxt_bytes\texpected\tstatus"
}
