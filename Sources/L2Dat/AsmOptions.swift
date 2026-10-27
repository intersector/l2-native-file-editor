/// Options for `Assembler.run` (mirrors the l2asm flags).
public struct AsmOptions: Sendable, Equatable {
    /// Encode every ASCF as 8-bit regardless of its `a,`/`u,` hint (`-f`).
    public var forceEightBit: Bool
    /// The txt has no header line regardless of the DDF `HEADER` variable (`-q`).
    public var noHeader: Bool
    /// Interpretation of 8-bit ASCF strings (`-a`).
    public var charset: Charset
    /// Legacy transliteration (`-l`). Not supported in v1: `run` throws `.unsupported`.
    public var legacyTransliteration: Bool

    public init(
        forceEightBit: Bool = false,
        noHeader: Bool = false,
        charset: Charset = .isoLatin1,
        legacyTransliteration: Bool = false
    ) {
        self.forceEightBit = forceEightBit
        self.noHeader = noHeader
        self.charset = charset
        self.legacyTransliteration = legacyTransliteration
    }
}
