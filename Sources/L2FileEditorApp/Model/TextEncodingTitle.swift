import L2Crypt

/// Display names of the text encodings a decrypted file can have.
enum TextEncodingTitle {
    static func of(_ encoding: TextCodec.Encoding) -> String {
        switch encoding {
        case let .utf16LE(bom): return bom ? "UTF-16LE (BOM)" : "UTF-16LE"
        case let .utf8(bom): return bom ? "UTF-8 (BOM)" : "UTF-8"
        case .latin1: return "ISO-8859-1"
        }
    }
}
