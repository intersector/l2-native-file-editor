/// Output of `Disassembler.run`.
public struct DisasmResult: Sendable {
    /// The txt bytes (UTF-8, LF line endings).
    public let txt: [UInt8]
    /// The input schema with effective soft limits filled in: feed it to `Assembler.run` or
    /// `DDF.export` (the `-new.ddf`).
    public let schema: Schema
    public let recordCount: Int
    public let warnings: [L2DatWarning]
}
