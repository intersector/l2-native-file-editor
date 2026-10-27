/// DDF entry points.
public enum DDF {
    /// Parses DDF text (any line endings, comments allowed). `fileName` is used in error messages.
    public static func parse(_ bytes: [UInt8], fileName: String) throws -> DDFDocument {
        var parser = DDFParser(bytes: bytes, fileName: fileName)
        return try parser.parse()
    }

    /// Writes the schema as l2disasm's `-e` export (`-new.ddf`): CRLF, normalised control
    /// variables, one field per line and the (effective) soft limits that l2asm requires.
    public static func export(_ schema: Schema) -> [UInt8] {
        DDFExporter.export(schema)
    }
}
