/// Assembles one txt row into binary record bytes, reading every value from the cell the
/// `ColumnPlan` assigns to it (natural column order, as l2asm expects).
struct RecordWriter {
    private let schema: Schema
    private let plan: ColumnPlan
    private let forceEightBit: Bool
    private let eightBitTarget: StringCodec.Target
    private(set) var writer: ByteWriter
    private(set) var warnings = WarningLog()
    /// Element-0 integer value of every field in the current row (table counters, ENBBY).
    private var values: [Int64]
    private var scratch: [UInt8] = []

    /// Where a fault happened, for the error message.
    private struct Position {
        var field: Int?
        var column = 0
    }

    private var position = Position()

    init(schema: Schema, plan: ColumnPlan, options: AsmOptions, capacity: Int) {
        self.schema = schema
        self.plan = plan
        forceEightBit = options.forceEightBit
        eightBitTarget = options.charset == .isoLatin1 ? .latin1 : .raw
        writer = ByteWriter(capacity: capacity)
        values = [Int64](repeating: 0, count: schema.fields.count)
        scratch.reserveCapacity(1024)
    }

    mutating func reserveCountSlot() -> Int {
        let offset = writer.bytes.count
        writer.u32(0)
        return offset
    }

    mutating func patchCount(_ count: UInt32, at offset: Int) { writer.patchU32(count, at: offset) }

    mutating func finish(magic: Int) { writer.safePackageTail(magic: magic) }

    mutating func warn(_ warning: L2DatWarning) { warnings.add(warning) }

    mutating func write(_ row: TxtRow) throws {
        if row.cellCount > plan.columns.count {
            throw L2DatError.txtFormat(
                line: row.line, column: row.displayColumn(cell: plan.columns.count, offset: 0), field: nil,
                message: "\(row.cellCount) cells, the DDF defines \(plan.columns.count) columns")
        }
        do {
            for fieldIndex in schema.fields.indices {
                position = Position(field: fieldIndex)
                values[fieldIndex] = 0
                let field = schema.fields[fieldIndex]
                guard field.isEnabled(values: values) else { continue }
                try writeField(fieldIndex, field, row)
            }
        } catch let fault as FormatFault {
            throw L2DatError.txtFormat(
                line: row.line, column: row.displayColumn(cell: position.column, offset: fault.offset),
                field: position.field.map { schema.fields[$0].ident }, message: fault.message)
        }
    }

    private mutating func writeField(_ fieldIndex: Int, _ field: SchemaField, _ row: TxtRow) throws {
        switch field.type {
        case .mtx, .mtx2, .mtx3:
            let meshes = try count(fieldIndex, .meshCount, limit: field.softM ?? 0, row)
            for i in 0..<meshes {
                try unicode(fieldIndex, .mesh, i, row)
                if field.type == .mtx2 {
                    writer.u32(UInt32(truncatingIfNeeded: try integer(fieldIndex, .meshID, i, row)))
                    writer.u8(UInt8(truncatingIfNeeded: try integer(fieldIndex, .meshCnt, i, row)))
                } else if field.type == .mtx3 {
                    writer.u8(UInt8(truncatingIfNeeded: try integer(fieldIndex, .meshByte1, i, row)))
                    writer.u8(UInt8(truncatingIfNeeded: try integer(fieldIndex, .meshByte2, i, row)))
                }
            }
            let textures = try count(fieldIndex, .textureCount, limit: field.softT ?? 0, row)
            for i in 0..<textures { try unicode(fieldIndex, .texture, i, row) }
            if field.type == .mtx3 { try unicode(fieldIndex, .textureExtra, 0, row) }

        case .mat, .mat2:
            let materials = try count(fieldIndex, .materialCount, limit: field.softM ?? 0, row)
            if field.type == .mat2 {
                writer.u32(UInt32(truncatingIfNeeded: try integer(fieldIndex, .materialExtra, 0, row)))
            }
            for i in 0..<materials {
                writer.u32(UInt32(truncatingIfNeeded: try integer(fieldIndex, .materialID, i, row)))
                writer.u32(UInt32(truncatingIfNeeded: try integer(fieldIndex, .materialValue, i, row)))
            }

        case .filler:
            guard case let .filler(length) = field.count else { return }
            let fill = UInt8(truncatingIfNeeded: try integer(fieldIndex, .element, 0, row))
            for _ in 0..<length { writer.u8(fill) }

        default:
            let elements: Int
            switch field.count {
            case .one, .filler: elements = 1
            case let .fixed(n): elements = n
            case let .dynamic(counter):
                let value = values[counter]
                let limit = field.soft ?? 0
                guard value >= 0, value <= Int64(limit) else {
                    throw FormatFault(
                        offset: 0,
                        message: "counter '\(schema.fields[counter].ident)' = \(value) is negative or above SOFT = \(limit)")
                }
                elements = Int(value)
            }
            for i in 0..<elements {
                let value = try scalar(fieldIndex, field.type, i, row)
                if i == 0 { values[fieldIndex] = value }
            }
        }
    }

    /// Writes one scalar and returns its integer value (0 for non-integers).
    private mutating func scalar(_ fieldIndex: Int, _ type: FieldType, _ i: Int, _ row: TxtRow) throws -> Int64 {
        switch type {
        case .uint, .int, .hex:
            let value = try integer(fieldIndex, .element, i, row, hex: type == .hex)
            writer.u32(UInt32(truncatingIfNeeded: value))
            return type == .int ? Int64(Int32(truncatingIfNeeded: value)) : Int64(UInt32(truncatingIfNeeded: value))
        case .uword, .word:
            let value = try integer(fieldIndex, .element, i, row)
            writer.u16(UInt16(truncatingIfNeeded: value))
            return type == .word ? Int64(Int16(truncatingIfNeeded: value)) : Int64(UInt16(truncatingIfNeeded: value))
        case .uchar, .chex, .char:
            let value = try integer(fieldIndex, .element, i, row, hex: type == .chex)
            writer.u8(UInt8(truncatingIfNeeded: value))
            return type == .char ? Int64(Int8(truncatingIfNeeded: value)) : Int64(UInt8(truncatingIfNeeded: value))
        case .cntr:
            let value = try integer(fieldIndex, .element, i, row)
            guard value.magnitude <= UInt64(UInt32.max) else {
                throw FormatFault(offset: 0, message: "CNTR value \(value) exceeds 32 bits")
            }
            writer.compactIndex(magnitude: UInt32(value.magnitude), negative: value < 0)
            return Int64(value.magnitude)
        case .float:
            let cell = locate(fieldIndex, .element, i, row)
            if cell.isEmpty {
                emptyCell(fieldIndex, row)
                writer.u32(0)
            } else {
                guard let bits = NumberText.parseFloatBits(cell) else {
                    throw FormatFault(offset: 0, message: "'\(String(decoding: cell, as: UTF8.self))' is not a FLOAT")
                }
                writer.u32(bits)
            }
            return 0
        case .ascf:
            try ascf(fieldIndex, i, row)
            return 0
        case .unicode:
            try unicode(fieldIndex, .element, i, row)
            return 0
        case .mat, .mat2, .mtx, .mtx2, .mtx3, .filler:
            return 0
        }
    }

    /// Selects the cell of one value and remembers it for error positions.
    @inline(__always)
    private mutating func locate(_ fieldIndex: Int, _ part: LeafPart, _ i: Int, _ row: TxtRow) -> UnsafeRawBufferPointer {
        let column = plan.column(field: fieldIndex, part: part, index: i)
        position.column = column
        return row.cell(column)
    }

    private mutating func emptyCell(_ fieldIndex: Int, _ row: TxtRow) {
        warnings.add(L2DatWarning(
            line: row.line, field: schema.fields[fieldIndex].ident, message: "empty value written as 0"))
    }

    /// Integer cell; callers truncate to the field width (C-cast semantics). Empty reads as 0.
    private mutating func integer(
        _ fieldIndex: Int, _ part: LeafPart, _ i: Int, _ row: TxtRow, hex: Bool = false
    ) throws -> Int64 {
        let cell = locate(fieldIndex, part, i, row)
        if cell.isEmpty {
            emptyCell(fieldIndex, row)
            return 0
        }
        guard let value = hex ? NumberText.parseHex(cell) : NumberText.parseInteger(cell) else {
            throw FormatFault(
                offset: 0, message: "'\(String(decoding: cell, as: UTF8.self))' is not \(hex ? "a hex" : "an integer") value")
        }
        return value
    }

    /// MTX/MAT counters: `0 ...` soft limit, written as INT.
    private mutating func count(_ fieldIndex: Int, _ part: LeafPart, limit: Int, _ row: TxtRow) throws -> Int {
        let value = try integer(fieldIndex, part, 0, row)
        guard value >= 0, value <= Int64(limit) else {
            throw FormatFault(offset: 0, message: "counter \(value) is negative or above the soft limit \(limit)")
        }
        writer.u32(UInt32(value))
        return Int(value)
    }

    /// `i32` byte length + UTF-16LE.
    private mutating func unicode(_ fieldIndex: Int, _ part: LeafPart, _ i: Int, _ row: TxtRow) throws {
        let cell = locate(fieldIndex, part, i, row)
        let lengthOffset = writer.bytes.count
        writer.u32(0)
        let units = try StringCodec.decode(cell, as: .utf16LE, into: &writer.bytes)
        guard units <= RecordReader.maxStringLength else {
            throw FormatFault(offset: 0, message: "UNICODE of \(units) characters exceeds \(RecordReader.maxStringLength)")
        }
        writer.patchU32(UInt32(units * 2), at: lengthOffset)
    }

    /// `a,<text>` (8-bit, positive compact length) or `u,<text>` (UTF-16LE, negative length).
    /// The length counts bytes or code units; there is no implicit terminator.
    private mutating func ascf(_ fieldIndex: Int, _ i: Int, _ row: TxtRow) throws {
        let cell = locate(fieldIndex, .element, i, row)
        guard cell.count >= 2, cell[1] == UInt8(ascii: ","),
              cell[0] == UInt8(ascii: "a") || cell[0] == UInt8(ascii: "u")
        else {
            throw FormatFault(offset: 0, message: "ASCF value must start with 'a,' or 'u,'")
        }
        let wide = cell[0] == UInt8(ascii: "u") && !forceEightBit
        let text = UnsafeRawBufferPointer(rebasing: cell[2...])
        scratch.removeAll(keepingCapacity: true)
        let units: Int
        do {
            units = try StringCodec.decode(text, as: wide ? .utf16LE : eightBitTarget, into: &scratch)
        } catch let fault as FormatFault {
            throw FormatFault(offset: fault.offset + 2, message: fault.message)
        }
        guard units <= RecordReader.maxStringLength else {
            throw FormatFault(offset: 0, message: "ASCF of \(units) characters exceeds \(RecordReader.maxStringLength)")
        }
        writer.compactIndex(magnitude: UInt32(units), negative: wide)
        writer.append(scratch)
    }
}
