/// The DDF control variables (MANUAL §1d) with their documented defaults.
public struct DDFControls: Sendable, Equatable {
    /// Field separator bytes (`FS`).
    public var fs: [UInt8]
    /// `RECCNT`: `-1` (OFF) means the record count is stored in the file.
    public var recCnt: Int
    public var mtxCntOut: Bool
    public var matCntOut: Bool
    public var ordIgnore: Bool
    public var header: Bool
    public var magic: Int

    public init(
        fs: [UInt8] = [0x09], recCnt: Int = -1, mtxCntOut: Bool = true, matCntOut: Bool = true,
        ordIgnore: Bool = false, header: Bool = true, magic: Int = 0
    ) {
        self.fs = fs
        self.recCnt = recCnt
        self.mtxCntOut = mtxCntOut
        self.matCntOut = matCntOut
        self.ordIgnore = ordIgnore
        self.header = header
        self.magic = magic
    }
}
