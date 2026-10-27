/// `.dat` -> `.txt` (l2disasm): two streaming passes over the binary with one `RecordReader`.
public enum Disassembler {
    /// Disassembles a decrypted `.dat`. Pass 1 collects the soft limits (column counts of dynamic
    /// tables and compounds), pass 2 emits the txt with the resulting column plan.
    public static func run(dat: [UInt8], schema: Schema, options: DisasmOptions = DisasmOptions()) throws -> DisasmResult {
        if options.legacyTransliteration {
            throw L2DatError.unsupported("legacy transliteration (-l) is not available in this version")
        }
        let reader = RecordReader(schema: schema)
        return try dat.withUnsafeBytes { buffer in
            var collector = SoftLimitCollector(fieldCount: schema.fields.count)
            let summary = try reader.read(buffer, into: &collector)
            let effective = collector.applied(to: schema)

            let plan = try ColumnPlan(schema: effective)
            try checkOutputSize(plan: plan, schema: effective, records: summary.records, datSize: dat.count)
            var emitter = TxtEmitter(
                plan: plan, schema: effective, options: options, capacity: dat.count * 2 + 4096)
            if effective.controls.header, !options.noHeader { emitter.writeHeader() }
            _ = try RecordReader(schema: effective).read(buffer, into: &emitter)

            var warnings = WarningLog()
            if !summary.hasTail {
                warnings.add(L2DatWarning(message: "the file has no SafePackage marker after the last record"))
            }
            return DisasmResult(
                txt: emitter.output, schema: effective, recordCount: summary.records, warnings: warnings.finished)
        }
    }

    /// Pass 1 raises every SOFT to the largest observed count, so each record then carries
    /// `outputOrder.count - 1` separators however short it is. Refuse before pass 2 allocates the
    /// txt when that lower bound passes `max(1 GiB, 32 x dat size)`.
    private static func checkOutputSize(plan: ColumnPlan, schema: Schema, records: Int, datSize: Int) throws {
        let separators = max(0, plan.outputOrder.count - 1)
        let limit = max(1 << 30, datSize.multipliedReportingOverflow(by: 32).partialValue)
        let (perRecord, overflowA) = separators.multipliedReportingOverflow(by: schema.controls.fs.count)
        let (total, overflowB) = perRecord.multipliedReportingOverflow(by: records)
        guard overflowA || overflowB || total > limit else { return }
        func largestSoft(_ field: SchemaField) -> Int { max(field.soft ?? 0, field.softM ?? 0, field.softT ?? 0) }
        let widest = schema.fields.max { largestSoft($0) < largestSoft($1) }
        throw L2DatError.outputTooLarge(
            field: widest?.ident ?? "", soft: widest.map(largestSoft) ?? 0, records: records,
            estimatedBytes: overflowA || overflowB ? Int.max : total, limit: limit)
    }
}
