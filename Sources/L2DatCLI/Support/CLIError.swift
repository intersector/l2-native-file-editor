/// An error detected by the command line tool itself (file access, argument checks).
struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }

    /// `-l` of l2disasm/l2asm: accepted for compatibility, not implemented.
    static let legacyTransliteration = CLIError(
        "legacy transliteration unsupported: -l is accepted for compatibility with l2disasm/l2asm, "
            + "but this version has no 'dumb' transliteration")
}
