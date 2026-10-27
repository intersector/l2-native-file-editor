import L2Dat

/// Small builders for synthetic DDF/dat/txt inputs, exercised through the public API only.
enum Fixtures {
    static let tail: [UInt8] = [0x0C] + Array("SafePackage".utf8) + [0x00]

    static func schema(_ ddf: String) throws -> Schema {
        try Schema(DDF.parse(Array(ddf.utf8), fileName: "test.ddf"))
    }

    static func le32(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 24)]
    }

    /// `u32 count` + records + SafePackage tail (RECCNT = OFF layout).
    static func dat(records: Int, _ body: [UInt8]) -> [UInt8] {
        le32(UInt32(records)) + body + tail
    }

    static func utf16(_ text: String) -> [UInt8] {
        text.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }
    }

    static func disasm(_ ddf: String, _ dat: [UInt8], options: DisasmOptions = DisasmOptions()) throws -> String {
        String(decoding: try Disassembler.run(dat: dat, schema: try schema(ddf), options: options).txt, as: UTF8.self)
    }

    static func asm(_ ddf: String, _ txt: String, options: AsmOptions = AsmOptions()) throws -> [UInt8] {
        try Assembler.run(txt: Array(txt.utf8), schema: try schema(ddf), options: options)
    }
}
