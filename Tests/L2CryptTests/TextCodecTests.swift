import L2Crypt
import Testing

private func utf16LE(_ text: String) -> [UInt8] {
    text.utf16.flatMap { [UInt8(truncatingIfNeeded: $0), UInt8(truncatingIfNeeded: $0 >> 8)] }
}

private let sample = "[Engine]\r\nLanguage=int\r\nName=Ωμέγα 🗡\r\n"

@Test func utf16LEWithBOMRoundTrips() throws {
    let bytes = [0xFF, 0xFE] + utf16LE(sample)
    let decoded = try TextCodec.decode(bytes)
    #expect(decoded.encoding == .utf16LE(bom: true))
    #expect(decoded.text == sample)
    #expect(try TextCodec.encode(decoded.text, as: decoded.encoding) == bytes)
}

@Test func utf16LEWithoutBOMRoundTrips() throws {
    let bytes = utf16LE(sample)
    let decoded = try TextCodec.decode(bytes)
    #expect(decoded.encoding == .utf16LE(bom: false))
    #expect(decoded.text == sample)
    #expect(try TextCodec.encode(decoded.text, as: decoded.encoding) == bytes)
}

@Test func utf8RoundTripsWithAndWithoutBOM() throws {
    for bom in [false, true] {
        let bytes = (bom ? [0xEF, 0xBB, 0xBF] : []) + Array(sample.utf8)
        let decoded = try TextCodec.decode(bytes)
        #expect(decoded.encoding == .utf8(bom: bom))
        #expect(decoded.text == sample)
        #expect(try TextCodec.encode(decoded.text, as: decoded.encoding) == bytes)
    }
}

@Test func invalidUTF8FallsBackToLatin1AndRoundTrips() throws {
    let bytes: [UInt8] = Array("caf".utf8) + [0xE9, 0x0D, 0x0A, 0x80, 0xFF]
    let decoded = try TextCodec.decode(bytes)
    #expect(decoded.encoding == .latin1)
    #expect(decoded.text.hasPrefix("café"))
    #expect(try TextCodec.encode(decoded.text, as: decoded.encoding) == bytes)
}

@Test func editedTextKeepsEncodingAndBOM() throws {
    let decoded = try TextCodec.decode([0xFF, 0xFE] + utf16LE("a=1\r\n"))
    #expect(try TextCodec.encode("a=2\r\n", as: decoded.encoding) == [0xFF, 0xFE] + utf16LE("a=2\r\n"))
}

@Test func emptyInputIsUTF8() throws {
    let decoded = try TextCodec.decode([])
    #expect(decoded == TextCodec.Decoded(text: "", encoding: .utf8(bom: false)))
}

@Test func malformedUTF16Throws() {
    #expect(throws: L2CryptError.malformedText(encoding: "UTF-16LE", offset: 4)) {
        try TextCodec.decode([0xFF, 0xFE, 0x41, 0x00, 0x00])
    }
    // Unpaired high surrogate at byte offset 4.
    #expect(throws: L2CryptError.malformedText(encoding: "UTF-16LE", offset: 4)) {
        try TextCodec.decode([0xFF, 0xFE, 0x41, 0x00, 0x3D, 0xD8, 0x41, 0x00])
    }
}

@Test func latin1RejectsWideCharacters() {
    #expect(throws: L2CryptError.unencodableText(encoding: "ISO-8859-1", offset: 1)) {
        try TextCodec.encode("aΩ", as: .latin1)
    }
}
