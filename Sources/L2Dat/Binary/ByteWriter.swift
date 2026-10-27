/// Little-endian `.dat` builder.
struct ByteWriter {
    var bytes: [UInt8] = []

    init(capacity: Int = 0) {
        bytes.reserveCapacity(capacity)
    }

    @inline(__always) mutating func u8(_ value: UInt8) { bytes.append(value) }

    @inline(__always) mutating func u16(_ value: UInt16) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    @inline(__always) mutating func u32(_ value: UInt32) {
        bytes.append(UInt8(truncatingIfNeeded: value))
        bytes.append(UInt8(truncatingIfNeeded: value >> 8))
        bytes.append(UInt8(truncatingIfNeeded: value >> 16))
        bytes.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    mutating func patchU32(_ value: UInt32, at offset: Int) {
        bytes[offset] = UInt8(truncatingIfNeeded: value)
        bytes[offset + 1] = UInt8(truncatingIfNeeded: value >> 8)
        bytes[offset + 2] = UInt8(truncatingIfNeeded: value >> 16)
        bytes[offset + 3] = UInt8(truncatingIfNeeded: value >> 24)
    }

    /// Minimal-length compact index: `b0 = sign | (v & 0x3F) | (more ? 0x40 : 0)`, then 7-bit
    /// groups with 0x80 as the continuation flag.
    mutating func compactIndex(magnitude: UInt32, negative: Bool) {
        var value = magnitude
        var first: UInt8 = (negative ? 0x80 : 0) | UInt8(value & 0x3F)
        value >>= 6
        if value != 0 { first |= 0x40 }
        bytes.append(first)
        while value != 0 {
            var byte = UInt8(value & 0x7F)
            value >>= 7
            if value != 0 { byte |= 0x80 }
            bytes.append(byte)
        }
    }

    mutating func append(_ other: [UInt8]) { bytes.append(contentsOf: other) }

    /// The file tail l2asm writes: `MAGIC` zero dwords, then FString "SafePackage".
    mutating func safePackageTail(magic: Int) {
        for _ in 0..<magic { u32(0) }
        bytes.append(contentsOf: SafePackage.marker)
    }
}
