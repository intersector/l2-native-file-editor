/// `.txt` -> `.dat` (l2asm).
public enum Assembler {
    /// Assembles a txt with a schema that carries soft limits (an exported `-new.ddf` or the
    /// schema returned by `Disassembler.run`) and returns the decrypted `.dat` bytes.
    public static func run(txt: [UInt8], schema: Schema, options: AsmOptions = AsmOptions()) throws -> [UInt8] {
        try assemble(txt: txt, schema: schema, options: options).dat
    }

    /// Same as `run`, also returning the row count and the warnings (empty values read as 0,
    /// header mismatch, RECCNT mismatch).
    public static func assemble(txt: [UInt8], schema: Schema, options: AsmOptions = AsmOptions()) throws -> AsmResult {
        if options.legacyTransliteration {
            throw L2DatError.unsupported("legacy transliteration (-l) is not available in this version")
        }
        let plan = try ColumnPlan(schema: schema)
        var writer = RecordWriter(schema: schema, plan: plan, options: options, capacity: txt.count)
        let countSlot = schema.controls.recCnt < 0 ? writer.reserveCountSlot() : nil
        let expectHeader = schema.controls.header && !options.noHeader
        let header = plan.header(separator: schema.controls.fs, order: Array(plan.columns.indices))
        var rows = 0
        try txt.withUnsafeBytes { buffer in
            try TxtScanner(separator: schema.controls.fs).scan(buffer) { row in
                if expectHeader, row.line == 1 {
                    let line = UnsafeRawBufferPointer(rebasing: buffer[row.lineStart..<(row.ends.last ?? row.lineStart)])
                    if !line.elementsEqual(header) {
                        writer.warn(L2DatWarning(line: 1, message: "header line does not match the DDF column names"))
                    }
                    return
                }
                try writer.write(row)
                rows += 1
            }
        }
        if let countSlot {
            guard rows <= Int(UInt32.max) else { throw L2DatError.unsupported("more than 2^32 rows") }
            writer.patchCount(UInt32(rows), at: countSlot)
        } else if rows != schema.controls.recCnt {
            writer.warn(L2DatWarning(message: "\(rows) rows written, the DDF says RECCNT = \(schema.controls.recCnt)"))
        }
        writer.finish(magic: schema.controls.magic)
        return AsmResult(dat: writer.writer.bytes, rowCount: rows, warnings: writer.warnings.finished)
    }
}
