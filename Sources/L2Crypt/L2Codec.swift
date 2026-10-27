import Foundation

/// Decrypts and encrypts Lineage II client files.
///
/// `L2Crypt` implements it with the bundled `l2encdec` helper; an in-process implementation
/// can conform later without changing callers. Cancelling the calling task stops a running
/// decode or encode and throws.
public protocol L2Codec: Sendable {
    /// Decrypts `input` into `output`.
    /// - Parameters:
    ///   - protocol: Protocol to decode with; `nil` reads it from the file header.
    ///   - legacyKeys: Use the original NCSoft RSA keys (protocols 411–414).
    ///   - originalFileName: File name the protocol-121 XOR key is derived from, when `input` is a renamed copy.
    /// - Returns: The protocol the file was decoded with.
    func decode(
        input: URL, output: URL, protocol: L2Protocol?, legacyKeys: Bool, originalFileName: String?
    ) async throws -> L2Protocol

    /// Encrypts `input` into `output` with `protocol`.
    /// - Parameter originalFileName: File name the protocol-121 XOR key is derived from, when `input` is a renamed copy.
    func encode(input: URL, output: URL, protocol: L2Protocol, originalFileName: String?) async throws
}
