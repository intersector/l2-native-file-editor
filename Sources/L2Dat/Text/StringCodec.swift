/// String payloads <-> escaped UTF-8 txt cells, byte-wise on buffers.
///
/// Escapes (as the original l2disasm): `\` `TAB` `NUL` `CR` `LF` become `\\` `\t` `\0` `\r` `\n`;
/// nothing else is escaped.
enum StringCodec {
    /// Where an unescaped cell goes in the `.dat`.
    enum Target {
        /// UTF-16LE code units (ASCF `u,`, UNICODE, MTX strings).
        case utf16LE
        /// ISO-8859-1 bytes: every scalar must be <= U+00FF.
        case latin1
        /// Raw bytes after unescaping (`-a UTF-8`).
        case raw
    }

    // MARK: - dat -> txt

    @inline(__always)
    static func appendEscaped(_ byte: UInt8, to out: inout [UInt8]) {
        switch byte {
        case 0x5C: out.append(0x5C); out.append(0x5C)
        case 0x09: out.append(0x5C); out.append(UInt8(ascii: "t"))
        case 0x00: out.append(0x5C); out.append(UInt8(ascii: "0"))
        case 0x0D: out.append(0x5C); out.append(UInt8(ascii: "r"))
        case 0x0A: out.append(0x5C); out.append(UInt8(ascii: "n"))
        default: out.append(byte)
        }
    }

    /// 8-bit string, ISO-8859-1 -> UTF-8, escaped.
    static func appendLatin1(_ bytes: UnsafeRawBufferPointer, to out: inout [UInt8]) {
        for byte in bytes {
            if byte < 0x80 {
                appendEscaped(byte, to: &out)
            } else {
                out.append(0xC0 | byte >> 6)
                out.append(0x80 | byte & 0x3F)
            }
        }
    }

    /// 8-bit string passed through unchanged, escaped.
    static func appendRaw(_ bytes: UnsafeRawBufferPointer, to out: inout [UInt8]) {
        for byte in bytes { appendEscaped(byte, to: &out) }
    }

    /// UTF-16LE -> UTF-8, escaped. Surrogate pairs are combined; a lone surrogate throws
    /// `FormatFault` with the byte offset inside `bytes`.
    static func appendUTF16LE(_ bytes: UnsafeRawBufferPointer, to out: inout [UInt8]) throws {
        let units = bytes.count / 2
        var index = 0
        while index < units {
            let unit = UInt32(bytes[2 * index]) | UInt32(bytes[2 * index + 1]) << 8
            index += 1
            if unit < 0x80 {
                appendEscaped(UInt8(unit), to: &out)
            } else if unit < 0x800 {
                out.append(UInt8(0xC0 | unit >> 6))
                out.append(UInt8(0x80 | unit & 0x3F))
            } else if unit & 0xF800 != 0xD800 {
                out.append(UInt8(0xE0 | unit >> 12))
                out.append(UInt8(0x80 | (unit >> 6) & 0x3F))
                out.append(UInt8(0x80 | unit & 0x3F))
            } else {
                guard unit < 0xDC00, index < units else {
                    throw FormatFault(offset: 2 * (index - 1), message: String(unpairedSurrogate: unit))
                }
                let low = UInt32(bytes[2 * index]) | UInt32(bytes[2 * index + 1]) << 8
                guard low & 0xFC00 == 0xDC00 else {
                    throw FormatFault(offset: 2 * (index - 1), message: String(unpairedSurrogate: unit))
                }
                index += 1
                let scalar = 0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00)
                out.append(UInt8(0xF0 | scalar >> 18))
                out.append(UInt8(0x80 | (scalar >> 12) & 0x3F))
                out.append(UInt8(0x80 | (scalar >> 6) & 0x3F))
                out.append(UInt8(0x80 | scalar & 0x3F))
            }
        }
    }

    // MARK: - txt -> dat

    /// Unescapes `cell` and encodes it for `target`, appending to `out`. Returns the number of
    /// code units written (UTF-16 units or bytes). Faults carry the byte offset inside `cell`.
    static func decode(_ cell: UnsafeRawBufferPointer, as target: Target, into out: inout [UInt8]) throws -> Int {
        var units = 0
        var index = 0
        let count = cell.count
        while index < count {
            let start = index
            let lead = cell[index]
            index += 1
            var scalar: UInt32
            if lead == 0x5C {
                guard index < count else { throw FormatFault(offset: start, message: "dangling '\\' at end of cell") }
                let escaped = cell[index]
                index += 1
                switch escaped {
                case 0x5C: scalar = 0x5C
                case UInt8(ascii: "t"): scalar = 0x09
                case UInt8(ascii: "0"): scalar = 0x00
                case UInt8(ascii: "r"): scalar = 0x0D
                case UInt8(ascii: "n"): scalar = 0x0A
                default:
                    throw FormatFault(offset: start, message: "unknown escape '\\\(Character(Unicode.Scalar(escaped)))'")
                }
            } else if lead < 0x80 || target == .raw {
                scalar = UInt32(lead)
            } else {
                let length: Int
                switch lead {
                case 0xC2...0xDF: length = 1; scalar = UInt32(lead & 0x1F)
                case 0xE0...0xEF: length = 2; scalar = UInt32(lead & 0x0F)
                case 0xF0...0xF4: length = 3; scalar = UInt32(lead & 0x07)
                default: throw FormatFault(offset: start, message: "invalid UTF-8")
                }
                guard count - index >= length else { throw FormatFault(offset: start, message: "truncated UTF-8 sequence") }
                for _ in 0..<length {
                    let next = cell[index]
                    guard next & 0xC0 == 0x80 else { throw FormatFault(offset: start, message: "invalid UTF-8") }
                    scalar = scalar << 6 | UInt32(next & 0x3F)
                    index += 1
                }
                let minimum: UInt32 = length == 1 ? 0x80 : (length == 2 ? 0x800 : 0x10000)
                guard scalar >= minimum, scalar <= 0x10FFFF, scalar & 0x1FF800 != 0xD800 else {
                    throw FormatFault(offset: start, message: "invalid UTF-8")
                }
            }
            switch target {
            case .raw:
                out.append(UInt8(truncatingIfNeeded: scalar))
                units += 1
            case .latin1:
                guard scalar <= 0xFF else {
                    throw FormatFault(offset: start, message: "character U+\(hex(scalar)) does not fit an 8-bit string")
                }
                out.append(UInt8(scalar))
                units += 1
            case .utf16LE:
                if scalar < 0x10000 {
                    out.append(UInt8(truncatingIfNeeded: scalar))
                    out.append(UInt8(truncatingIfNeeded: scalar >> 8))
                    units += 1
                } else {
                    let value = scalar - 0x10000
                    let high = 0xD800 | value >> 10, low = 0xDC00 | value & 0x3FF
                    out.append(UInt8(truncatingIfNeeded: high))
                    out.append(UInt8(truncatingIfNeeded: high >> 8))
                    out.append(UInt8(truncatingIfNeeded: low))
                    out.append(UInt8(truncatingIfNeeded: low >> 8))
                    units += 2
                }
            }
        }
        return units
    }

    private static func hex(_ value: UInt32) -> String {
        var bytes: [UInt8] = []
        NumberText.appendHex(UInt64(value), to: &bytes)
        while bytes.count < 4 { bytes.insert(0x30, at: 0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private extension String {
    init(unpairedSurrogate unit: UInt32) {
        var bytes: [UInt8] = []
        NumberText.appendHex(UInt64(unit), to: &bytes)
        self = "unpaired UTF-16 surrogate 0x" + String(decoding: bytes, as: UTF8.self)
    }
}
