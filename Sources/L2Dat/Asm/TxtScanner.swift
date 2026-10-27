
/// Splits a txt into lines on LF (one trailing CR stripped) and lines into cells on the field
/// separator. A final line without LF still counts; the empty remainder after the last LF does not.
struct TxtScanner {
    let separator: [UInt8]

    func scan(_ text: UnsafeRawBufferPointer, _ body: (inout TxtRow) throws -> Void) rethrows {
        var row = TxtRow(text: text)
        let count = text.count
        let first = separator.first ?? 0x09
        let multiByte = separator.count > 1
        var position = 0
        var line = 0
        while position < count {
            line += 1
            row.line = line
            row.lineStart = position
            row.starts.removeAll(keepingCapacity: true)
            row.ends.removeAll(keepingCapacity: true)
            var cellStart = position
            var index = position
            while index < count {
                let byte = text[index]
                if byte == 0x0A { break }
                if byte == first, !multiByte || matchesSeparator(text, at: index) {
                    row.starts.append(cellStart)
                    row.ends.append(index)
                    index += separator.count
                    cellStart = index
                } else {
                    index += 1
                }
            }
            var lineEnd = min(index, count)
            if lineEnd > cellStart, text[lineEnd - 1] == 0x0D { lineEnd -= 1 }
            row.starts.append(cellStart)
            row.ends.append(max(cellStart, lineEnd))
            position = index + 1
            try body(&row)
        }
    }

    private func matchesSeparator(_ text: UnsafeRawBufferPointer, at index: Int) -> Bool {
        guard index + separator.count <= text.count else { return false }
        for offset in 1..<separator.count where text[index + offset] != separator[offset] { return false }
        return true
    }
}
