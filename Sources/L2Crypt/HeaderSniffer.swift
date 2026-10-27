/// Reads the protocol from the UTF-16LE `Lineage2Ver###` header of an encrypted client file.
public enum HeaderSniffer {
    /// Header size in bytes: 14 UTF-16LE code units.
    public static let headerLength = 28

    private static let prefix: [UInt8] = Array("Lineage2Ver".utf8)

    /// Returns the protocol named by the first 28 bytes of `head`, or `nil` when the bytes are
    /// not a `Lineage2Ver###` header or name a protocol the helper does not support.
    public static func protocolOf(_ head: [UInt8]) -> L2Protocol? {
        guard head.count >= headerLength else { return nil }
        for (index, byte) in prefix.enumerated() {
            guard head[2 * index] == byte, head[2 * index + 1] == 0 else { return nil }
        }
        var value = 0
        for unit in prefix.count..<(headerLength / 2) {
            let low = head[2 * unit]
            let high = head[2 * unit + 1]
            guard high == 0, low >= 0x30, low <= 0x39 else { return nil }
            value = value * 10 + Int(low - 0x30)
        }
        return L2Protocol(rawValue: value)
    }
}
