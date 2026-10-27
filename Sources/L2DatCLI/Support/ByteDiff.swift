/// The first difference between two byte buffers, with its 1-based line/column in `expected`.
struct ByteDiff: Sendable {
    let offset: Int
    let line: Int
    let column: Int
    let actualCount: Int
    let expectedCount: Int

    /// nil when the buffers are equal.
    static func between(_ actual: [UInt8], _ expected: [UInt8]) -> ByteDiff? {
        if actual == expected { return nil }
        let common = min(actual.count, expected.count)
        let offset = actual.withUnsafeBufferPointer { lhs in
            expected.withUnsafeBufferPointer { rhs in
                var index = 0
                while index < common, lhs[index] == rhs[index] { index += 1 }
                return index
            }
        }
        var line = 1
        var lineStart = 0
        expected.withUnsafeBufferPointer { bytes in
            for index in 0..<offset where bytes[index] == 0x0A {
                line += 1
                lineStart = index + 1
            }
        }
        return ByteDiff(
            offset: offset, line: line, column: offset - lineStart + 1,
            actualCount: actual.count, expectedCount: expected.count)
    }

    /// For text: the offset plus its line and byte column.
    var textDescription: String {
        "first difference at offset \(offset) (line \(line), column \(column)); sizes \(actualCount) vs \(expectedCount)"
    }

    /// For binary data, where lines mean nothing.
    var binaryDescription: String {
        "first difference at offset \(offset); sizes \(actualCount) vs \(expectedCount)"
    }
}
