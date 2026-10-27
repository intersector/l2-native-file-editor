/// Errors thrown by the crypto layer; every case carries the context needed to act on it.
public enum L2CryptError: Error, Sendable, Equatable, CustomStringConvertible {
    /// The helper ran and exited non-zero. `stderr` holds its message (e.g. `Failed to decompress file`).
    case helperFailed(exitCode: Int32, stdout: String, stderr: String, arguments: [String])
    /// No executable `l2encdec` was found at any of the searched paths.
    case helperNotFound(searched: [String])
    /// The helper exists but could not be started.
    case launchFailed(executable: String, reason: String)
    /// `decode` was asked to sniff the protocol but the file has no supported `Lineage2Ver###` header.
    case unrecognizedHeader(file: String)
    /// `decode` was given a protocol that differs from the one named in the file's own header.
    case protocolMismatch(file: String, header: L2Protocol, requested: L2Protocol)
    /// The input file could not be read.
    case unreadableFile(file: String, reason: String)
    /// The helper did not finish within `timeout`; it and every process it started were killed.
    case timedOut(executable: String, timeout: Duration)
    /// The task running the helper was cancelled; it and every process it started were killed (or it never started).
    case cancelled(executable: String)
    /// Decrypted text is not valid in the detected encoding; `offset` is the byte offset of the first bad unit.
    case malformedText(encoding: String, offset: Int)
    /// Edited text contains a character the file's encoding cannot represent; `offset` is its scalar index.
    case unencodableText(encoding: String, offset: Int)

    public var description: String {
        switch self {
        case let .helperFailed(exitCode, stdout, stderr, arguments):
            let message = Self.trimmed(stderr).isEmpty ? Self.trimmed(stdout) : Self.trimmed(stderr)
            return "l2encdec failed (exit \(exitCode)): \(message.isEmpty ? "no output" : message)\n"
                + "  arguments: \(arguments.joined(separator: " "))"
        case let .helperNotFound(searched):
            return "l2encdec helper not found. Searched:\n"
                + searched.map { "  \($0)" }.joined(separator: "\n")
                + "\nBuild it with scripts/build-l2encdec.sh or set L2ENCDEC to its path."
        case let .launchFailed(executable, reason):
            return "cannot launch \(executable): \(reason)"
        case let .unrecognizedHeader(file):
            return "\(file): no Lineage2Ver### header of a supported protocol; choose the protocol explicitly"
        case let .protocolMismatch(file, header, requested):
            return "\(file): header says \(header.header) but protocol \(requested.rawValue) was requested; "
                + "omit the protocol or pass \(header.rawValue)"
        case let .unreadableFile(file, reason):
            return "cannot read \(file): \(reason)"
        case let .timedOut(executable, timeout):
            return "\(executable) did not finish within \(timeout) and was stopped"
        case let .cancelled(executable):
            return "\(executable) was cancelled and stopped"
        case let .malformedText(encoding, offset):
            return "text is not valid \(encoding) at byte offset \(offset)"
        case let .unencodableText(encoding, offset):
            return "character at index \(offset) cannot be encoded as \(encoding)"
        }
    }

    private static func trimmed(_ text: String) -> String {
        var scalars = Substring(text)
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        while let first = scalars.first, first.isWhitespace { scalars.removeFirst() }
        return String(scalars)
    }
}
