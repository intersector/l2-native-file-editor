#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Number <-> txt cell bytes. Integers are formatted and parsed by hand; floats are formatted with
/// `vsnprintf("%.8f" | "%.8e")` and parsed with the C-locale `strtod` behind `Double(_:)`, then
/// narrowed to `Float` (FLOAT values travel as raw `UInt32` bits everywhere else).
enum NumberText {
    // MARK: - Formatting

    @inline(__always)
    static func appendDecimal(_ value: Int64, to out: inout [UInt8]) {
        if value < 0 {
            out.append(UInt8(ascii: "-"))
            appendUnsigned(value.magnitude, to: &out)
        } else {
            appendUnsigned(UInt64(value), to: &out)
        }
    }

    @inline(__always)
    static func appendUnsigned(_ value: UInt64, to out: inout [UInt8]) {
        if value < 10 {
            out.append(0x30 &+ UInt8(value))
            return
        }
        var digits: (UInt64, UInt64, UInt64, UInt64) = (0, 0, 0, 0) // 32 bytes of scratch
        withUnsafeMutableBytes(of: &digits) { buffer in
            var index = buffer.count
            var rest = value
            while rest != 0 {
                index -= 1
                buffer[index] = 0x30 &+ UInt8(rest % 10)
                rest /= 10
            }
            out.append(contentsOf: buffer[index...])
        }
    }

    /// `%X`: uppercase, no padding, no prefix.
    static func appendHex(_ value: UInt64, to out: inout [UInt8]) {
        let digits: StaticString = "0123456789ABCDEF"
        var shift = 60
        while shift > 0, (value >> UInt64(shift)) & 0xF == 0 { shift -= 4 }
        digits.withUTF8Buffer { table in
            while shift >= 0 {
                out.append(table[Int((value >> UInt64(shift)) & 0xF)])
                shift -= 4
            }
        }
    }

    static func isNaN(bits: UInt32) -> Bool {
        bits & 0x7F80_0000 == 0x7F80_0000 && bits & 0x007F_FFFF != 0
    }

    /// `%.8f` (or `%.8e`) of the float widened to double; NaN prints as `NaN(0x<bits>)`.
    static func appendFloat(bits: UInt32, scientific: Bool, to out: inout [UInt8]) {
        if isNaN(bits: bits) {
            out.append(contentsOf: Array("NaN(0x".utf8))
            appendHex(UInt64(bits), to: &out)
            out.append(UInt8(ascii: ")"))
            return
        }
        let value = Double(Float(bitPattern: bits))
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 96) { buffer in
            guard let base = buffer.baseAddress else { return }
            let length = withVaList([value]) { args in
                vsnprintf(base, buffer.count, scientific ? "%.8e" : "%.8f", args)
            }
            let count = min(Int(max(length, 0)), buffer.count - 1)
            appendNormalizingDecimalPoint(UnsafeRawBufferPointer(start: base, count: count), to: &out)
        }
    }

    /// `vsnprintf` honours `LC_NUMERIC`; whatever separator a host locale put after the leading
    /// digit run is rewritten to `.` so the txt never depends on the process locale.
    private static func appendNormalizingDecimalPoint(_ text: UnsafeRawBufferPointer, to out: inout [UInt8]) {
        var index = 0
        while index < text.count, !isDigit(text[index]) {
            out.append(text[index])
            index += 1
        }
        while index < text.count, isDigit(text[index]) {
            out.append(text[index])
            index += 1
        }
        if index < text.count, text[index] != UInt8(ascii: "e"), text[index] != UInt8(ascii: "E") {
            out.append(UInt8(ascii: "."))
            while index < text.count, !isDigit(text[index]) { index += 1 }
        }
        while index < text.count {
            out.append(text[index])
            index += 1
        }
    }

    @inline(__always)
    private static func isDigit(_ byte: UInt8) -> Bool { byte &- 0x30 < 10 }

    // MARK: - Parsing

    /// Decimal integer with an optional sign. nil for empty, garbage or overflow beyond 64 bits.
    static func parseInteger(_ cell: UnsafeRawBufferPointer) -> Int64? {
        var index = 0
        var negative = false
        if let first = cell.first, first == UInt8(ascii: "-") || first == UInt8(ascii: "+") {
            negative = first == UInt8(ascii: "-")
            index = 1
        }
        guard index < cell.count else { return nil }
        var magnitude: UInt64 = 0
        while index < cell.count {
            let digit = cell[index] &- 0x30
            guard digit < 10 else { return nil }
            let (times, overflow1) = magnitude.multipliedReportingOverflow(by: 10)
            let (sum, overflow2) = times.addingReportingOverflow(UInt64(digit))
            guard !overflow1, !overflow2 else { return nil }
            magnitude = sum
            index += 1
        }
        if negative {
            guard magnitude <= UInt64(Int64.max) + 1 else { return nil }
            return magnitude == UInt64(Int64.max) + 1 ? Int64.min : -Int64(magnitude)
        }
        guard magnitude <= UInt64(Int64.max) else { return nil }
        return Int64(magnitude)
    }

    /// Hex digits (either case) with an optional `0x` prefix.
    static func parseHex(_ cell: UnsafeRawBufferPointer) -> Int64? {
        var index = 0
        if cell.count > 2, cell[0] == UInt8(ascii: "0"), cell[1] | 0x20 == UInt8(ascii: "x") { index = 2 }
        guard index < cell.count, cell.count - index <= 16 else { return nil }
        var value: UInt64 = 0
        while index < cell.count {
            let byte = cell[index]
            let digit: UInt8
            switch byte {
            case 0x30...0x39: digit = byte - 0x30
            case 0x41...0x46: digit = byte - 0x41 + 10
            case 0x61...0x66: digit = byte - 0x61 + 10
            default: return nil
            }
            value = value << 4 | UInt64(digit)
            index += 1
        }
        return Int64(bitPattern: value)
    }

    /// `NaN(0x<bits>)` or a decimal float; nil when the cell is not a number.
    static func parseFloatBits(_ cell: UnsafeRawBufferPointer) -> UInt32? {
        let prefix = Array("NaN(0x".utf8)
        if cell.count > prefix.count + 1, cell.starts(with: prefix), cell[cell.count - 1] == UInt8(ascii: ")") {
            let digits = UnsafeRawBufferPointer(rebasing: cell[prefix.count..<(cell.count - 1)])
            guard let bits = parseHex(digits), bits >= 0, bits <= Int64(UInt32.max) else { return nil }
            return UInt32(bits)
        }
        guard !cell.isEmpty, cell.count <= 400 else { return nil }
        guard let value = Double(String(decoding: cell, as: UTF8.self)) else { return nil }
        return Float(value).bitPattern
    }
}
