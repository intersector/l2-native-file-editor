/// A DDF resolved for reading and writing: references point at field indices and the soft limits
/// are either declared (input schema) or effective (the schema returned by a disassembly).
public struct Schema: Sendable, Equatable {
    public let fileName: String
    public let controls: DDFControls
    public internal(set) var fields: [SchemaField]

    /// Resolves `document`. Table counters and ENBBY references bind to the nearest *preceding*
    /// field with that name (DDFs contain duplicate names) and must be integer fields.
    public init(_ document: DDFDocument) throws {
        fileName = document.fileName
        controls = document.controls
        let limits = 0...0x100000
        guard !controls.fs.isEmpty, !controls.fs.contains(0x0A), controls.recCnt >= -1, controls.magic >= 0,
              controls.magic <= 0xFFFF else {
            throw L2DatError.ddfSchema(file: document.fileName, field: "", message: "invalid control variables")
        }
        var fields: [SchemaField] = []
        fields.reserveCapacity(document.fields.count)
        for field in document.fields {
            func fail(_ message: String) -> L2DatError {
                .ddfSchema(file: document.fileName, field: field.ident, message: message)
            }
            func resolve(_ ref: String, role: String) throws -> Int {
                guard let index = fields.lastIndex(where: { $0.ident == ref }) else {
                    throw fail("\(role) '\(ref)' does not name a preceding field")
                }
                guard fields[index].type.isInteger else {
                    throw fail("\(role) '\(ref)' is a \(fields[index].type.rawValue), not an integer field")
                }
                return index
            }

            for limit in [field.soft, field.softM, field.softT] {
                if let limit, !limits.contains(limit) { throw fail("soft limit \(limit) out of range") }
            }
            let count: SchemaField.Count
            switch field.table {
            case .none: count = .one
            case let .fixed(n):
                guard limits.contains(n) else { throw fail("table size \(n) out of range") }
                count = .fixed(n)
            case let .dynamic(ref): count = .dynamic(try resolve(ref, role: "table counter"))
            case let .filler(n):
                guard field.type == .filler, limits.contains(n) else { throw fail("invalid FILLER size") }
                count = .filler(n)
            }
            if field.type == .filler {
                guard case .filler = count else { throw fail("FILLER needs a {count}") }
            }
            if field.type.isCompound, count != .one {
                throw fail("tables of \(field.type.rawValue) are not supported")
            }
            let enbby = try field.enbby.map { line in
                try line.map { condition in
                    SchemaCondition(
                        field: try resolve(condition.ref, role: "ENBBY reference"),
                        mask: UInt32(bitPattern: condition.mask),
                        value: UInt32(truncatingIfNeeded: condition.value),
                        writtenValue: condition.value)
                }
            }
            fields.append(SchemaField(
                type: field.type, ident: field.ident, count: count, enbby: enbby, ord: field.ord,
                skipIf: field.skipIf, soft: field.soft, softM: field.softM, softT: field.softT))
        }
        self.fields = fields
    }
}
