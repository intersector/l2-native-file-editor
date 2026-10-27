/// Little-endian cursor over a decrypted `.dat` buffer. Every read is bounds-checked and throws
/// `FormatFault` at the current offset instead of trapping.
struct ByteReader {
    let base: UnsafeRawBufferPointer
    private(set) var offset: Int

    init(_ base: UnsafeRawBufferPointer, offset: Int = 0) {
        self.base = base
        self.offset = offset
    }

    var remaining: Int { base.count - offset }

    @inline(__always)
    private func need(_ count: Int) throws {
        guard count <= base.count - offset else {
            throw FormatFault(
                offset: offset, message: "unexpected end of data (need \(count) bytes, \(remaining) left)")
        }
    }

    @inline(__always)
    mutating func u8() throws -> UInt8 {
        try need(1)
        let value = base[offset]
        offset += 1
        return value
    }

    @inline(__always)
    mutating func u16() throws -> UInt16 {
        try need(2)
        let value = base.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
        offset += 2
        return UInt16(littleEndian: value)
    }

    @inline(__always)
    mutating func u32() throws -> UInt32 {
        try need(4)
        let value = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
        offset += 4
        return UInt32(littleEndian: value)
    }

    @inline(__always)
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func bytes(_ count: Int) throws -> UnsafeRawBufferPointer {
        try need(count)
        let slice = UnsafeRawBufferPointer(rebasing: base[offset..<(offset + count)])
        offset += count
        return slice
    }

    /// Unreal compact index, matching the original l2disasm: byte 0 holds the sign (bit 7),
    /// a continuation flag (bit 6) and 6 data bits; each following byte holds 7 data bits and a
    /// continuation flag (bit 7). Returns the magnitude and the sign ("wide") flag separately.
    mutating func compactIndex() throws -> (magnitude: UInt32, negative: Bool) {
        let start = offset
        let first = try u8()
        let negative = first & 0x80 != 0
        var value = UInt64(first & 0x7F)
        if value & 0x40 == 0 { return (UInt32(value), negative) }
        value &= 0x3F
        var shift: UInt64 = 6
        while true {
            let byte = try u8()
            value += UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 { break }
            shift += 7
            guard shift <= 34 else { throw FormatFault(offset: start, message: "compact index longer than 6 bytes") }
        }
        guard value <= UInt64(UInt32.max) else {
            throw FormatFault(offset: start, message: "compact index exceeds 32 bits")
        }
        return (UInt32(value), negative)
    }
}
