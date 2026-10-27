/// Pass 1: records the largest count seen per dynamic table / compound part.
struct SoftLimitCollector: RecordSink {
    private(set) var maxElements: [Int]
    private(set) var maxMeshes: [Int]
    private(set) var maxTextures: [Int]

    init(fieldCount: Int) {
        maxElements = [Int](repeating: 0, count: fieldCount)
        maxMeshes = maxElements
        maxTextures = maxElements
    }

    mutating func observeCount(field: Int, part: LeafPart, count: Int) {
        switch part {
        case .textureCount: maxTextures[field] = max(maxTextures[field], count)
        case .meshCount, .materialCount: maxMeshes[field] = max(maxMeshes[field], count)
        default: maxElements[field] = max(maxElements[field], count)
        }
    }

    /// Effective limits: `max(1, declared, observed)` on every field that needs one.
    func applied(to schema: Schema) -> Schema {
        var schema = schema
        for index in schema.fields.indices {
            let field = schema.fields[index]
            guard field.needsSoftLimit else { continue }
            if field.type.isCompound {
                schema.fields[index].softM = max(1, field.softM ?? 0, maxMeshes[index])
                if field.usesSoftT {
                    schema.fields[index].softT = max(1, field.softT ?? 0, maxTextures[index])
                }
            } else {
                schema.fields[index].soft = max(1, field.soft ?? 0, maxElements[index])
            }
        }
        return schema
    }

    mutating func integer(field: Int, part: LeafPart, index: Int, value: Int64, hex: Bool) {}
    mutating func float(field: Int, index: Int, bits: UInt32) {}
    mutating func ascf(field: Int, index: Int, bytes: UnsafeRawBufferPointer, wide: Bool) {}
    mutating func unicode(field: Int, part: LeafPart, index: Int, bytes: UnsafeRawBufferPointer) {}
    mutating func endRecord() {}
}
