/// Receives the values `RecordReader` decodes, in binary order. Pass 1 (`SoftLimitCollector`)
/// only looks at counts; pass 2 (`TxtEmitter`) formats values into txt cells. Values that are not
/// present in a record (ENBBY-disabled field, element beyond the count) are simply not reported.
protocol RecordSink {
    /// Soft-limit relevant counts: dynamic table lengths (`.element`), MTX/MAT mesh/material
    /// counts (`.meshCount`/`.materialCount`) and MTX texture counts (`.textureCount`).
    mutating func observeCount(field: Int, part: LeafPart, count: Int)
    mutating func integer(field: Int, part: LeafPart, index: Int, value: Int64, hex: Bool)
    mutating func float(field: Int, index: Int, bits: UInt32)
    /// ASCF payload without its length prefix; `wide` = UTF-16LE.
    mutating func ascf(field: Int, index: Int, bytes: UnsafeRawBufferPointer, wide: Bool) throws
    /// UTF-16LE payload of UNICODE fields and MTX strings.
    mutating func unicode(field: Int, part: LeafPart, index: Int, bytes: UnsafeRawBufferPointer) throws
    mutating func endRecord()
}
