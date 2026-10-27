/// One SKIPIF pair `(index .. index, value .. value)`: table elements whose index and value fall
/// in both inclusive ranges are printed as empty cells.
public struct SkipIfRule: Sendable, Equatable {
    public var indexLow: Int
    public var indexHigh: Int
    public var valueLow: Double
    public var valueHigh: Double

    public init(indexLow: Int, indexHigh: Int, valueLow: Double, valueHigh: Double) {
        self.indexLow = indexLow
        self.indexHigh = indexHigh
        self.valueLow = valueLow
        self.valueHigh = valueHigh
    }

    func matches(index: Int, value: Double) -> Bool {
        index >= indexLow && index <= indexHigh && value >= valueLow && value <= valueHigh
    }
}
