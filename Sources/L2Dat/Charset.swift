/// How 8-bit (`a,`) ASCF strings are interpreted (l2disasm/l2asm `-a`).
public enum Charset: String, Sendable, CaseIterable {
    /// ISO-8859-1: byte 0xNN is U+00NN. The original tools' default.
    case isoLatin1
    /// Bytes are passed through unchanged (`-a UTF-8`).
    case utf8
}
