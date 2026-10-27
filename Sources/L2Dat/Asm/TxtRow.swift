/// One txt line split into cells (byte ranges into the txt buffer; no copies, no Strings).
struct TxtRow {
    let text: UnsafeRawBufferPointer
    /// 1-based line number.
    var line = 0
    var lineStart = 0
    var starts: [Int] = []
    var ends: [Int] = []

    var cellCount: Int { starts.count }

    /// Cell `column`; columns beyond the end of the line read as empty.
    @inline(__always)
    func cell(_ column: Int) -> UnsafeRawBufferPointer {
        guard column < starts.count else { return UnsafeRawBufferPointer(start: nil, count: 0) }
        return UnsafeRawBufferPointer(rebasing: text[starts[column]..<ends[column]])
    }

    /// 1-based column, in Unicode scalars, of byte `offset` inside cell `column`.
    func displayColumn(cell column: Int, offset: Int) -> Int {
        let target = column < starts.count ? starts[column] + offset : (ends.last ?? lineStart)
        var scalars = 0
        var index = lineStart
        while index < target, index < text.count {
            if text[index] & 0xC0 != 0x80 { scalars += 1 }
            index += 1
        }
        return scalars + 1
    }
}
