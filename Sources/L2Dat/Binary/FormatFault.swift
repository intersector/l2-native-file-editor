/// Internal low-level failure raised by primitives and codecs. The record reader/writer catches it
/// and rethrows an `L2DatError` enriched with record, field and line context.
struct FormatFault: Error {
    /// Byte offset: absolute in the `.dat` for binary faults, relative to the cell for text faults.
    let offset: Int
    let message: String
}
