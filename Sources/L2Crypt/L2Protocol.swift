/// Lineage II client file protocols supported by the `l2encdec` helper.
///
/// The raw value is the number in the file header (`Lineage2Ver413` → `.v413`) and the
/// value passed to the helper's `-p` option.
public enum L2Protocol: Int, CaseIterable, Sendable {
    /// XOR with a fixed key.
    case v111 = 111
    /// XOR with a position-derived key.
    case v120 = 120
    /// XOR with a key derived from the file name (needs the original name).
    case v121 = 121
    /// Blowfish.
    case v211 = 211
    /// Blowfish.
    case v212 = 212
    /// RSA + zlib.
    case v411 = 411
    /// RSA + zlib.
    case v412 = 412
    /// RSA + zlib (High Five and later clients).
    case v413 = 413
    /// RSA + zlib.
    case v414 = 414

    /// The ASCII header text, e.g. `Lineage2Ver413`; stored as UTF-16LE in the first 28 bytes.
    public var header: String { "Lineage2Ver\(rawValue)" }
}
