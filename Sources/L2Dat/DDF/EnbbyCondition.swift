/// `(ref:mask, value)` inside an ENBBY list: enabled when `(ref & mask) == value`.
public struct EnbbyCondition: Sendable, Equatable {
    public var ref: String
    public var mask: Int32
    public var value: Int64

    public init(ref: String, mask: Int32 = -1, value: Int64) {
        self.ref = ref
        self.mask = mask
        self.value = value
    }
}
