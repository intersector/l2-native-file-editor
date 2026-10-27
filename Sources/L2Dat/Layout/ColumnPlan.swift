/// The txt column layout of a schema with known soft limits: the single source of truth for the
/// header names, for where each value lands when disassembling and for which cell each value is
/// read from when assembling.
///
/// `columns` is the natural order (every column, fields in DDF order) that l2asm expects.
/// `outputOrder` is what l2disasm prints: ORD-sorted fields, ORD=OFF fields dropped and compound
/// counters dropped when MTXCNT_OUT / MATCNT_OUT = NO.
struct ColumnPlan {
    struct Column {
        let name: [UInt8]
        let field: Int
        let isCounter: Bool
    }

    let columns: [Column]
    let outputOrder: [Int]
    private let fieldBase: [Int]
    private let softM: [Int]
    private let softT: [Int]
    /// MTX: 1 column per mesh; MTX2/MTX3: 3.
    private let meshStride: [Int]
    /// Offset of the first MAT pair: MAT 1, MAT2 2 (after `_extra`).
    private let materialOffset: [Int]

    init(schema: Schema) throws {
        var columns: [Column] = []
        var fieldBase: [Int] = []
        var softM: [Int] = []
        var softT: [Int] = []
        var meshStride: [Int] = []
        var materialOffset: [Int] = []
        for (index, field) in schema.fields.enumerated() {
            func missingLimit(_ name: String) -> L2DatError {
                .ddfSchema(file: schema.fileName, field: field.ident, message: "has no soft limit (\(name))")
            }
            fieldBase.append(columns.count)
            let ident = Array(field.ident.utf8)
            func add(_ suffix: String = "", counter: Bool = false) {
                columns.append(Column(name: ident + Array(suffix.utf8), field: index, isCounter: counter))
            }
            var m = 0, t = 0, stride = 1, matOffset = 1
            switch field.type {
            case .mtx, .mtx2, .mtx3:
                guard let limitM = field.softM else { throw missingLimit("SOFTM") }
                guard let limitT = field.softT else { throw missingLimit("SOFTT") }
                m = limitM
                t = limitT
                if field.type != .mtx { stride = 3 }
                add("_cntm", counter: true)
                for i in 0..<m {
                    switch field.type {
                    case .mtx:
                        add("_m[\(i)]")
                    case .mtx2:
                        add("_m[\(i)]")
                        add("_m[\(i)]_id")
                        add("_m[\(i)]_cnt")
                    default:
                        add("_mU[\(i)]")
                        add("_mB[\(i)][1]")
                        add("_mB[\(i)][2]")
                    }
                }
                add("_cntt", counter: true)
                for i in 0..<t { add("_t[\(i)]") }
                if field.type == .mtx3 { add("_tE") }
            case .mat, .mat2:
                guard let limitM = field.softM else { throw missingLimit("SOFTM") }
                m = limitM
                add("_cnt", counter: true)
                if field.type == .mat2 {
                    matOffset = 2
                    add("_extra")
                }
                for i in 0..<m {
                    add("_m[\(i)]_id")
                    add("_m[\(i)]_cnt")
                }
            default:
                switch field.count {
                case .one:
                    add()
                case let .fixed(n):
                    if n == 1 { add() } else { for i in 0..<n { add("[\(i)]") } }
                case .dynamic:
                    guard let soft = field.soft else { throw missingLimit("SOFT") }
                    if soft == 1 { add() } else { for i in 0..<soft { add("[\(i)]") } }
                case let .filler(n):
                    add("{\(n)}")
                }
            }
            softM.append(m)
            softT.append(t)
            meshStride.append(stride)
            materialOffset.append(matOffset)
        }

        var orderedFields = Array(schema.fields.indices)
        if !schema.controls.ordIgnore {
            let ranked = orderedFields
                .filter { (schema.fields[$0].ord ?? -1) != -1 }
                .enumerated()
                .sorted { ($0.element.ord(in: schema), $0.offset) < ($1.element.ord(in: schema), $1.offset) }
                .map(\.element)
            let unranked = orderedFields.filter { schema.fields[$0].ord == nil }
            orderedFields = ranked + unranked
        }
        var outputOrder: [Int] = []
        outputOrder.reserveCapacity(columns.count)
        for fieldIndex in orderedFields {
            let field = schema.fields[fieldIndex]
            let showCounters = field.type == .mat || field.type == .mat2
                ? schema.controls.matCntOut : schema.controls.mtxCntOut
            let end = fieldIndex + 1 < fieldBase.count ? fieldBase[fieldIndex + 1] : columns.count
            for column in fieldBase[fieldIndex]..<end where showCounters || !columns[column].isCounter {
                outputOrder.append(column)
            }
        }

        self.columns = columns
        self.outputOrder = outputOrder
        self.fieldBase = fieldBase
        self.softM = softM
        self.softT = softT
        self.meshStride = meshStride
        self.materialOffset = materialOffset
    }

    /// Natural column index of one value.
    @inline(__always)
    func column(field: Int, part: LeafPart, index: Int) -> Int {
        let base = fieldBase[field]
        switch part {
        case .element: return base + index
        case .meshCount, .materialCount: return base
        case .mesh: return base + 1 + meshStride[field] * index
        case .meshID, .meshByte1: return base + 2 + 3 * index
        case .meshCnt, .meshByte2: return base + 3 + 3 * index
        case .textureCount: return base + 1 + meshStride[field] * softM[field]
        case .texture: return base + 2 + meshStride[field] * softM[field] + index
        case .textureExtra: return base + 2 + meshStride[field] * softM[field] + softT[field]
        case .materialExtra: return base + 1
        case .materialID: return base + materialOffset[field] + 2 * index
        case .materialValue: return base + materialOffset[field] + 1 + 2 * index
        }
    }

    /// Header line (without the trailing newline) in output order.
    func header(separator: [UInt8], order: [Int]) -> [UInt8] {
        var line: [UInt8] = []
        for (position, column) in order.enumerated() {
            if position > 0 { line.append(contentsOf: separator) }
            line.append(contentsOf: columns[column].name)
        }
        return line
    }
}

private extension Int {
    func ord(in schema: Schema) -> Int32 { schema.fields[self].ord ?? -1 }
}
