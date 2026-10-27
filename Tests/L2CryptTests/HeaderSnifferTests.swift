import L2Crypt
import Testing

private func header(_ text: String, padTo length: Int = 28) -> [UInt8] {
    var bytes: [UInt8] = []
    for unit in text.utf16 {
        bytes.append(UInt8(truncatingIfNeeded: unit))
        bytes.append(UInt8(truncatingIfNeeded: unit >> 8))
    }
    while bytes.count < length { bytes.append(0xAB) }
    return bytes
}

@Test func snifferDetectsLineage2Ver413() {
    #expect(HeaderSniffer.protocolOf(header("Lineage2Ver413")) == .v413)
}

@Test(arguments: L2Protocol.allCases)
func snifferDetectsEverySupportedProtocol(_ proto: L2Protocol) {
    #expect(HeaderSniffer.protocolOf(header(proto.header, padTo: 64)) == proto)
}

@Test func snifferRejectsNonHeaders() {
    #expect(HeaderSniffer.protocolOf([]) == nil)
    #expect(HeaderSniffer.protocolOf(Array(header("Lineage2Ver413").prefix(27))) == nil)
    #expect(HeaderSniffer.protocolOf(header("Lineage2Ver999")) == nil)
    #expect(HeaderSniffer.protocolOf(header("Lineage2Ver41x")) == nil)
    #expect(HeaderSniffer.protocolOf(header("lineage2Ver413")) == nil)
    #expect(HeaderSniffer.protocolOf(Array("Lineage2Ver413Lineage2Ver413".utf8)) == nil)
}
