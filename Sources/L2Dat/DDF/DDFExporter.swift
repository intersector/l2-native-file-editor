/// Byte-exact writer of the l2disasm `-e` DDF format.
enum DDFExporter {
    static func export(_ schema: Schema) -> [UInt8] {
        var out: [UInt8] = []
        func line(_ text: String) {
            out.append(contentsOf: Array(text.utf8))
            out.append(0x0D)
            out.append(0x0A)
        }
        func flag(_ value: Bool) -> String { value ? "YES" : "NO" }

        let controls = schema.controls
        line("FS = \"\(quoted(controls.fs))\";")
        line("RECCNT = \(controls.recCnt < 0 ? "OFF" : String(controls.recCnt));")
        line("HEADER = \(flag(controls.header));")
        line("MTXCNT_OUT = \(flag(controls.mtxCntOut));")
        line("MATCNT_OUT = \(flag(controls.matCntOut));")
        line("MAGIC = \(controls.magic);")
        line("ORD_IGNORE = \(flag(controls.ordIgnore));")
        line("")
        line("{")
        for field in schema.fields {
            let suffix: String
            switch field.count {
            case .one: suffix = ""
            case let .fixed(n): suffix = "[\(n)]"
            case let .dynamic(counter): suffix = "[\(schema.fields[counter].ident)]"
            case let .filler(n): suffix = "{\(n)}"
            }
            line("\t\(field.type.rawValue) \(field.ident)\(suffix);")
            for conditions in field.enbby {
                let list = conditions.map { condition in
                    "(\(schema.fields[condition.field].ident): \(Int32(bitPattern: condition.mask)), \(condition.writtenValue))"
                }
                line("\t\tENBBY = [\(list.joined(separator: ", "))];")
            }
            if let ord = field.ord { line("\t\tORD = \(ord == -1 ? "OFF" : String(ord));") }
            if !field.skipIf.isEmpty {
                let list = field.skipIf.map { rule in
                    "(\(rule.indexLow) .. \(rule.indexHigh), \(decimal(rule.valueLow)) .. \(decimal(rule.valueHigh)))"
                }
                line("\t\tSKIPIF = [\(list.joined(separator: ", "))];")
            }
            if field.type.isCompound {
                if field.usesSoftT, let softT = field.softT { line("\t\tSOFTT = \(softT);") }
                if let softM = field.softM { line("\t\tSOFTM = \(softM);") }
            } else if case .dynamic = field.count, let soft = field.soft {
                line("\t\tSOFT = \(soft);")
            }
        }
        line("}")
        return out
    }

    /// FS inside double quotes: tab as `\t`, quote and backslash escaped.
    private static func quoted(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        for byte in bytes {
            switch byte {
            case 0x09: out.append(contentsOf: Array("\\t".utf8))
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\")); out.append(byte)
            default: out.append(byte)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// SKIPIF bounds as l2disasm prints them (`%.3f`).
    private static func decimal(_ value: Double) -> String {
        if value.isNaN { return "nan" }
        if value.isInfinite { return value < 0 ? "-inf" : "inf" }
        var out: [UInt8] = []
        let thousandths = (value * 1000).rounded()
        if thousandths < 0 { out.append(UInt8(ascii: "-")) }
        let magnitude = UInt64(min(thousandths.magnitude, 9.0e18))
        NumberText.appendUnsigned(magnitude / 1000, to: &out)
        out.append(UInt8(ascii: "."))
        let fraction = magnitude % 1000
        out.append(0x30 + UInt8(fraction / 100))
        out.append(0x30 + UInt8(fraction / 10 % 10))
        out.append(0x30 + UInt8(fraction % 10))
        return String(decoding: out, as: UTF8.self)
    }
}
