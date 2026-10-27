/// Walks a decrypted `.dat` record by record following a schema and pushes every present value
/// into a `RecordSink`. Used twice per disassembly (limits pass, then emission pass), so the
/// traversal rules live in exactly one place.
struct RecordReader {
    /// Upper bound of ASCF/UNICODE lengths in characters, as in l2disasm.
    static let maxStringLength = 0x18000

    struct Summary {
        let records: Int
        /// False when the file ends right after the last record (no SafePackage marker).
        let hasTail: Bool
    }

    let schema: Schema

    func read<Sink: RecordSink>(_ dat: UnsafeRawBufferPointer, into sink: inout Sink) throws -> Summary {
        let fields = schema.fields
        var reader = ByteReader(dat)
        var values = [Int64](repeating: 0, count: fields.count)
        var record: Int?
        var current: Int?
        do {
            let count = schema.controls.recCnt < 0 ? Int(try reader.u32()) : schema.controls.recCnt
            guard count <= reader.remaining else {
                throw FormatFault(offset: reader.offset, message: "record count \(count) exceeds the \(reader.remaining) bytes left")
            }
            for index in 0..<count {
                record = index
                for fieldIndex in fields.indices {
                    current = fieldIndex
                    values[fieldIndex] = 0
                    guard fields[fieldIndex].isEnabled(values: values) else { continue }
                    try readField(fieldIndex, fields[fieldIndex], &reader, &values, &sink)
                }
                current = nil
                sink.endRecord()
            }
            record = nil
            return Summary(records: count, hasTail: try readTail(&reader))
        } catch let fault as FormatFault {
            throw L2DatError.datFormat(
                record: record, field: current.map { fields[$0].ident }, offset: fault.offset, message: fault.message)
        }
    }

    private func readField<Sink: RecordSink>(
        _ fieldIndex: Int, _ field: SchemaField, _ reader: inout ByteReader, _ values: inout [Int64],
        _ sink: inout Sink
    ) throws {
        switch field.type {
        case .mtx, .mtx2, .mtx3:
            let meshes = try readCount(&reader)
            sink.observeCount(field: fieldIndex, part: .meshCount, count: meshes)
            sink.integer(field: fieldIndex, part: .meshCount, index: 0, value: Int64(meshes), hex: false)
            for i in 0..<meshes {
                try readUnicode(fieldIndex, .mesh, i, &reader, &sink)
                if field.type == .mtx2 {
                    sink.integer(field: fieldIndex, part: .meshID, index: i, value: Int64(try reader.u32()), hex: false)
                    sink.integer(field: fieldIndex, part: .meshCnt, index: i, value: Int64(try reader.u8()), hex: false)
                } else if field.type == .mtx3 {
                    sink.integer(field: fieldIndex, part: .meshByte1, index: i, value: Int64(try reader.u8()), hex: false)
                    sink.integer(field: fieldIndex, part: .meshByte2, index: i, value: Int64(try reader.u8()), hex: false)
                }
            }
            let textures = try readCount(&reader)
            sink.observeCount(field: fieldIndex, part: .textureCount, count: textures)
            sink.integer(field: fieldIndex, part: .textureCount, index: 0, value: Int64(textures), hex: false)
            for i in 0..<textures { try readUnicode(fieldIndex, .texture, i, &reader, &sink) }
            if field.type == .mtx3 { try readUnicode(fieldIndex, .textureExtra, 0, &reader, &sink) }

        case .mat, .mat2:
            let materials = try readCount(&reader)
            sink.observeCount(field: fieldIndex, part: .materialCount, count: materials)
            sink.integer(field: fieldIndex, part: .materialCount, index: 0, value: Int64(materials), hex: false)
            if field.type == .mat2 {
                sink.integer(field: fieldIndex, part: .materialExtra, index: 0, value: Int64(try reader.i32()), hex: false)
            }
            for i in 0..<materials {
                sink.integer(field: fieldIndex, part: .materialID, index: i, value: Int64(try reader.i32()), hex: false)
                sink.integer(field: fieldIndex, part: .materialValue, index: i, value: Int64(try reader.i32()), hex: false)
            }

        case .filler:
            guard case let .filler(length) = field.count else { return }
            let bytes = try reader.bytes(length)
            sink.integer(field: fieldIndex, part: .element, index: 0, value: Int64(bytes.first ?? 0), hex: false)

        default:
            let elements: Int
            switch field.count {
            case .one, .filler: elements = 1
            case let .fixed(n): elements = n
            case let .dynamic(counter):
                let value = values[counter]
                guard value >= 0, value <= Int64(Int32.max) else {
                    throw FormatFault(
                        offset: reader.offset,
                        message: "table counter '\(schema.fields[counter].ident)' = \(value) is out of range")
                }
                elements = Int(value)
                sink.observeCount(field: fieldIndex, part: .element, count: elements)
            }
            for i in 0..<elements {
                let value = try readScalar(fieldIndex, field.type, i, &reader, &sink)
                if i == 0 { values[fieldIndex] = value }
            }
        }
    }

    /// Reads one scalar and returns its integer value for counters/ENBBY (0 for non-integers).
    @inline(__always)
    private func readScalar<Sink: RecordSink>(
        _ fieldIndex: Int, _ type: FieldType, _ i: Int, _ reader: inout ByteReader, _ sink: inout Sink
    ) throws -> Int64 {
        let value: Int64
        switch type {
        case .uint, .hex: value = Int64(try reader.u32())
        case .int: value = Int64(try reader.i32())
        case .uword: value = Int64(try reader.u16())
        case .word: value = Int64(Int16(bitPattern: try reader.u16()))
        case .uchar, .chex: value = Int64(try reader.u8())
        case .char: value = Int64(Int8(bitPattern: try reader.u8()))
        case .cntr: value = Int64(try reader.compactIndex().magnitude)
        case .float:
            sink.float(field: fieldIndex, index: i, bits: try reader.u32())
            return 0
        case .ascf:
            let start = reader.offset
            let (length, wide) = try reader.compactIndex()
            guard length <= Self.maxStringLength else {
                throw FormatFault(offset: start, message: "ASCF length \(length) exceeds \(Self.maxStringLength)")
            }
            let payload = reader.offset
            let bytes = try reader.bytes(Int(length) << (wide ? 1 : 0))
            do {
                try sink.ascf(field: fieldIndex, index: i, bytes: bytes, wide: wide)
            } catch let fault as FormatFault {
                throw FormatFault(offset: payload + fault.offset, message: fault.message)
            }
            return 0
        case .unicode:
            try readUnicode(fieldIndex, .element, i, &reader, &sink)
            return 0
        case .mat, .mat2, .mtx, .mtx2, .mtx3, .filler:
            return 0
        }
        sink.integer(field: fieldIndex, part: .element, index: i, value: value, hex: type == .hex || type == .chex)
        return value
    }

    /// `i32` byte length (even, no terminator) + UTF-16LE.
    private func readUnicode<Sink: RecordSink>(
        _ fieldIndex: Int, _ part: LeafPart, _ i: Int, _ reader: inout ByteReader, _ sink: inout Sink
    ) throws {
        let start = reader.offset
        let length = try reader.i32()
        guard length >= 0, length & 1 == 0 else {
            throw FormatFault(offset: start, message: "UNICODE byte length \(length) is negative or odd")
        }
        guard Int(length) >> 1 <= Self.maxStringLength else {
            throw FormatFault(offset: start, message: "UNICODE string of \(length >> 1) characters is too large")
        }
        let payload = reader.offset
        let bytes = try reader.bytes(Int(length))
        do {
            try sink.unicode(field: fieldIndex, part: part, index: i, bytes: bytes)
        } catch let fault as FormatFault {
            throw FormatFault(offset: payload + fault.offset, message: fault.message)
        }
    }

    /// MTX/MAT counters are `INT`s and must not be negative.
    private func readCount(_ reader: inout ByteReader) throws -> Int {
        let start = reader.offset
        let count = try reader.i32()
        guard count >= 0 else { throw FormatFault(offset: start, message: "negative element count \(count)") }
        return Int(count)
    }

    /// After the records: nothing, or `MAGIC` dwords followed by the SafePackage marker.
    private func readTail(_ reader: inout ByteReader) throws -> Bool {
        let rest = reader.remaining
        if rest == 0 { return false }
        let expected = schema.controls.magic * 4 + SafePackage.marker.count
        if rest == expected {
            let start = reader.offset
            let tail = try reader.bytes(rest)
            if tail.suffix(SafePackage.marker.count).elementsEqual(SafePackage.marker) { return true }
            throw FormatFault(offset: start, message: "the file does not end with the SafePackage marker")
        }
        throw FormatFault(
            offset: reader.offset,
            message: "\(rest) unexpected bytes after the last record: the DDF does not match this file")
    }
}
