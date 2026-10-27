/// Output of `Assembler.assemble`.
public struct AsmResult: Sendable {
    /// The decrypted `.dat` bytes.
    public let dat: [UInt8]
    public let rowCount: Int
    public let warnings: [L2DatWarning]
}
