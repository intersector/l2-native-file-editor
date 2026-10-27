/// Pass 2: formats every value into its txt cell and writes one line per record in the plan's
/// output order. Cells that receive no value (absent data) stay empty.
struct TxtEmitter: RecordSink {
    private let plan: ColumnPlan
    private let skipIf: [[SkipIfRule]]
    private let separator: [UInt8]
    private let scientific: Bool
    private let forceAsciiHint: Bool
    private let charset: Charset
    private(set) var output: [UInt8] = []
    /// Cell bytes of the current record, addressed by `starts`/`ends` per natural column.
    private var cells: [UInt8] = []
    private var starts: [Int]
    private var ends: [Int]

    init(plan: ColumnPlan, schema: Schema, options: DisasmOptions, capacity: Int) {
        self.plan = plan
        skipIf = schema.fields.map(\.skipIf)
        separator = schema.controls.fs
        scientific = options.floatFormat == .scientific
        forceAsciiHint = options.forceAsciiHint
        charset = options.charset
        starts = [Int](repeating: 0, count: plan.columns.count)
        ends = starts
        output.reserveCapacity(capacity)
        cells.reserveCapacity(4096)
    }

    mutating func writeHeader() {
        output.append(contentsOf: plan.header(separator: separator, order: plan.outputOrder))
        output.append(0x0A)
    }

    mutating func observeCount(field: Int, part: LeafPart, count: Int) {}

    mutating func integer(field: Int, part: LeafPart, index: Int, value: Int64, hex: Bool) {
        if part == .element, !skipIf[field].isEmpty, skipIf[field].contains(where: { $0.matches(index: index, value: Double(value)) }) {
            return
        }
        let column = plan.column(field: field, part: part, index: index)
        starts[column] = cells.count
        if hex {
            NumberText.appendHex(UInt64(bitPattern: value), to: &cells)
        } else {
            NumberText.appendDecimal(value, to: &cells)
        }
        ends[column] = cells.count
    }

    mutating func float(field: Int, index: Int, bits: UInt32) {
        if !skipIf[field].isEmpty {
            let value = Double(Float(bitPattern: bits))
            if skipIf[field].contains(where: { $0.matches(index: index, value: value) }) { return }
        }
        let column = plan.column(field: field, part: .element, index: index)
        starts[column] = cells.count
        NumberText.appendFloat(bits: bits, scientific: scientific, to: &cells)
        ends[column] = cells.count
    }

    mutating func ascf(field: Int, index: Int, bytes: UnsafeRawBufferPointer, wide: Bool) throws {
        let column = plan.column(field: field, part: .element, index: index)
        starts[column] = cells.count
        cells.append(wide && !forceAsciiHint ? UInt8(ascii: "u") : UInt8(ascii: "a"))
        cells.append(UInt8(ascii: ","))
        if wide {
            try StringCodec.appendUTF16LE(bytes, to: &cells)
        } else if charset == .isoLatin1 {
            StringCodec.appendLatin1(bytes, to: &cells)
        } else {
            StringCodec.appendRaw(bytes, to: &cells)
        }
        ends[column] = cells.count
    }

    mutating func unicode(field: Int, part: LeafPart, index: Int, bytes: UnsafeRawBufferPointer) throws {
        let column = plan.column(field: field, part: part, index: index)
        starts[column] = cells.count
        try StringCodec.appendUTF16LE(bytes, to: &cells)
        ends[column] = cells.count
    }

    mutating func endRecord() {
        let singleSeparator = separator.count == 1 ? separator[0] : nil
        var first = true
        for column in plan.outputOrder {
            if first {
                first = false
            } else if let singleSeparator {
                output.append(singleSeparator)
            } else {
                output.append(contentsOf: separator)
            }
            let start = starts[column], end = ends[column]
            if end > start { output.append(contentsOf: cells[start..<end]) }
        }
        output.append(0x0A)
        cells.removeAll(keepingCapacity: true)
        for column in starts.indices {
            starts[column] = 0
            ends[column] = 0
        }
    }
}
