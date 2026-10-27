/// Options for `Disassembler.run` (mirrors the l2disasm flags).
public struct DisasmOptions: Sendable, Equatable {
    public enum FloatFormat: Sendable, Equatable {
        /// `%.8f` (default, `-o f`).
        case fixed
        /// `%.8e` (`-o e`).
        case scientific
    }

    public var floatFormat: FloatFormat
    /// Print every ASCF with the `a,` hint (`-f`).
    public var forceAsciiHint: Bool
    /// Suppress the header line regardless of the DDF `HEADER` variable (`-q`).
    public var noHeader: Bool
    /// Interpretation of 8-bit ASCF strings (`-a`).
    public var charset: Charset
    /// Legacy transliteration (`-l`). Not supported in v1: `run` throws `.unsupported`.
    public var legacyTransliteration: Bool

    public init(
        floatFormat: FloatFormat = .fixed,
        forceAsciiHint: Bool = false,
        noHeader: Bool = false,
        charset: Charset = .isoLatin1,
        legacyTransliteration: Bool = false
    ) {
        self.floatFormat = floatFormat
        self.forceAsciiHint = forceAsciiHint
        self.noHeader = noHeader
        self.charset = charset
        self.legacyTransliteration = legacyTransliteration
    }
}
