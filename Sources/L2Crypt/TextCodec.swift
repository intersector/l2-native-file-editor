/// Converts decrypted `.ini` / `.int` / `.htm` bytes to text and back.
///
/// `encode(decode(bytes))` reproduces `bytes` exactly: the detected encoding and byte-order
/// mark are kept in `Decoded.encoding` and reused on save.
public enum TextCodec {
    /// Text encoding of a decrypted file.
    public enum Encoding: Sendable, Equatable {
        /// UTF-16 little endian, optionally preceded by the `FF FE` byte-order mark.
        case utf16LE(bom: Bool)
        /// UTF-8, optionally preceded by the `EF BB BF` byte-order mark.
        case utf8(bom: Bool)
        /// ISO-8859-1: fallback for 8-bit files that are not valid UTF-8; every byte maps to U+0000–U+00FF.
        case latin1

        var name: String {
            switch self {
            case .utf16LE: return "UTF-16LE"
            case .utf8: return "UTF-8"
            case .latin1: return "ISO-8859-1"
            }
        }
    }

    /// Decoded text plus the encoding needed to write it back.
    public struct Decoded: Sendable, Equatable {
        public var text: String
        public var encoding: Encoding

        public init(text: String, encoding: Encoding) {
            self.text = text
            self.encoding = encoding
        }
    }

    private static let utf16BOM: [UInt8] = [0xFF, 0xFE]
    private static let utf8BOM: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// Detects the encoding: UTF-16LE BOM, UTF-8 BOM, BOM-less UTF-16LE (mostly-zero high bytes),
    /// valid UTF-8, otherwise ISO-8859-1.
    public static func detect(_ bytes: [UInt8]) -> Encoding {
        if bytes.starts(with: utf16BOM) { return .utf16LE(bom: true) }
        if bytes.starts(with: utf8BOM) { return .utf8(bom: true) }
        if looksLikeUTF16LE(bytes) { return .utf16LE(bom: false) }
        return validUTF8(bytes[...]) == nil ? .utf8(bom: false) : .latin1
    }

    /// Decodes `bytes` with the detected encoding.
    /// - Throws: `L2CryptError.malformedText` for UTF-16LE with an odd byte count or unpaired surrogates.
    public static func decode(_ bytes: [UInt8]) throws -> Decoded {
        let encoding = detect(bytes)
        switch encoding {
        case let .utf16LE(bom):
            let start = bom ? utf16BOM.count : 0
            return Decoded(text: try decodeUTF16LE(bytes, from: start), encoding: encoding)
        case let .utf8(bom):
            let body = bytes[(bom ? utf8BOM.count : 0)...]
            if let offset = validUTF8(body) {
                throw L2CryptError.malformedText(encoding: encoding.name, offset: offset)
            }
            return Decoded(text: String(decoding: body, as: UTF8.self), encoding: encoding)
        case .latin1:
            // Latin-1 → UTF-8 on a byte buffer (at most two bytes per input byte), then one String.
            let utf8 = [UInt8](unsafeUninitializedCapacity: bytes.count * 2) { buffer, count in
                var used = 0
                for byte in bytes {
                    if byte < 0x80 {
                        buffer[used] = byte
                        used += 1
                    } else {
                        buffer[used] = 0xC0 | byte >> 6
                        buffer[used + 1] = 0x80 | byte & 0x3F
                        used += 2
                    }
                }
                count = used
            }
            return Decoded(text: String(decoding: utf8, as: UTF8.self), encoding: encoding)
        }
    }

    /// Encodes `text` with `encoding`, writing the byte-order mark when the encoding has one.
    /// - Throws: `L2CryptError.unencodableText` for a scalar above U+00FF under ISO-8859-1.
    public static func encode(_ text: String, as encoding: Encoding) throws -> [UInt8] {
        switch encoding {
        case let .utf16LE(bom):
            var bytes = bom ? utf16BOM : []
            bytes.reserveCapacity(bytes.count + text.utf16.count * 2)
            for unit in text.utf16 {
                bytes.append(UInt8(truncatingIfNeeded: unit))
                bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
            }
            return bytes
        case let .utf8(bom):
            return (bom ? utf8BOM : []) + Array(text.utf8)
        case .latin1:
            var bytes: [UInt8] = []
            bytes.reserveCapacity(text.unicodeScalars.count)
            for (index, scalar) in text.unicodeScalars.enumerated() {
                guard scalar.value <= 0xFF else {
                    throw L2CryptError.unencodableText(encoding: encoding.name, offset: index)
                }
                bytes.append(UInt8(scalar.value))
            }
            return bytes
        }
    }

    /// BOM-less UTF-16LE: even length and at least half of the first 256 high bytes are zero.
    private static func looksLikeUTF16LE(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return false }
        let units = min(bytes.count / 2, 256)
        var zeroHigh = 0
        for unit in 0..<units where bytes[2 * unit + 1] == 0 {
            zeroHigh += 1
        }
        return zeroHigh * 2 >= units
    }

    /// Returns `nil` when `bytes` is valid UTF-8, else the offset of the first invalid sequence
    /// (relative to the start of `bytes`).
    private static func validUTF8(_ bytes: ArraySlice<UInt8>) -> Int? {
        var iterator = bytes.makeIterator()
        var parser = Unicode.UTF8.ForwardParser()
        var offset = 0
        while true {
            switch parser.parseScalar(from: &iterator) {
            case let .valid(encoded):
                offset += encoded.count
            case .emptyInput:
                return nil
            case .error:
                return offset
            }
        }
    }

    private static func decodeUTF16LE(_ bytes: [UInt8], from start: Int) throws -> String {
        guard (bytes.count - start) % 2 == 0 else {
            throw L2CryptError.malformedText(encoding: "UTF-16LE", offset: bytes.count - 1)
        }
        var units: [UInt16] = []
        units.reserveCapacity((bytes.count - start) / 2)
        var index = start
        while index < bytes.count {
            units.append(UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8)
            index += 2
        }
        var iterator = units.makeIterator()
        var parser = Unicode.UTF16.ForwardParser()
        var unitOffset = 0
        while true {
            switch parser.parseScalar(from: &iterator) {
            case let .valid(encoded):
                unitOffset += encoded.count
            case .emptyInput:
                return String(decoding: units, as: UTF16.self)
            case .error:
                throw L2CryptError.malformedText(encoding: "UTF-16LE", offset: start + unitOffset * 2)
            }
        }
    }
}
