import Foundation

/// `L2Codec` backed by the `l2encdec` helper executable.
public struct L2Crypt: L2Codec {
    /// The helper executable this codec runs.
    public let helper: URL
    /// Time limit of one helper run; nil for none. A run that exceeds it is stopped with its whole
    /// process group and throws `L2CryptError.timedOut`.
    public let timeout: Duration?

    public init(helper: URL, timeout: Duration? = nil) {
        self.helper = helper
        self.timeout = timeout
    }

    /// Uses the helper found by `L2CryptHelper.locate(overrides:)`.
    public init(overrides: [URL] = [], timeout: Duration? = nil) throws {
        self.init(helper: try L2CryptHelper.locate(overrides: overrides), timeout: timeout)
    }

    /// Prepares `stopRunningHelpers()` for a signal handler; call it before installing the handler.
    public static func prepareToStopHelpersFromSignalHandler() {
        LiveProcessGroups.prepare()
    }

    /// Kills the process group of every helper run in progress in this process with SIGKILL and waits
    /// until each group's leader has exited, so no helper writes a file after this returns. Async-signal-safe
    /// after `prepareToStopHelpersFromSignalHandler()`: it allocates nothing, takes no lock and only calls
    /// `killpg(2)` and `waitid(2)`. A helper spawned while it runs may be missed.
    public static func stopRunningHelpers() {
        LiveProcessGroups.killAll()
    }

    /// Cancelling the calling task stops the helper with its whole process group and throws
    /// `L2CryptError.cancelled`; exceeding `timeout` throws `L2CryptError.timedOut`.
    /// - Throws: `L2CryptError.protocolMismatch` when `requested` disagrees with the file's own
    ///   `Lineage2Ver###` header; protocols 411–414 share one format and count as equal. A file
    ///   without a valid header trusts `requested`.
    public func decode(
        input: URL,
        output: URL,
        protocol requested: L2Protocol? = nil,
        legacyKeys: Bool = false,
        originalFileName: String? = nil
    ) async throws -> L2Protocol {
        let sniffed = HeaderSniffer.protocolOf(try Self.readHead(of: input))
        let resolved: L2Protocol
        if let requested {
            if let sniffed, !Self.sameFormat(sniffed, requested) {
                throw L2CryptError.protocolMismatch(file: input.path, header: sniffed, requested: requested)
            }
            resolved = requested
        } else {
            guard let sniffed else {
                throw L2CryptError.unrecognizedHeader(file: input.path)
            }
            resolved = sniffed
        }
        var arguments = ["-c", "decode", "-p", String(resolved.rawValue), "-o", output.path]
        if legacyKeys {
            arguments.append("-l")
        }
        try await runHelper(arguments, protocol: resolved, originalFileName: originalFileName, input: input)
        return resolved
    }

    /// Cancellation and `timeout` behave as in `decode`.
    public func encode(
        input: URL,
        output: URL,
        protocol target: L2Protocol,
        originalFileName: String? = nil
    ) async throws {
        // Always pass -p: without it the helper guesses the protocol from the file name.
        let arguments = ["-c", "encode", "-p", String(target.rawValue), "-o", output.path]
        try await runHelper(arguments, protocol: target, originalFileName: originalFileName, input: input)
    }

    private func runHelper(
        _ options: [String], protocol target: L2Protocol, originalFileName: String?, input: URL
    ) async throws {
        var arguments = options
        if target == .v121, let originalFileName {
            arguments += ["-f", originalFileName]
        }
        // `--` ends option parsing so an input path is never read as a flag.
        arguments += ["--", input.path]
        let result = try await ProcessRunner(executable: helper, timeout: timeout).run(arguments)
        guard result.exitCode == 0 else {
            throw L2CryptError.helperFailed(
                exitCode: result.exitCode,
                stdout: String(decoding: result.stdout, as: UTF8.self),
                stderr: String(decoding: result.stderr, as: UTF8.self),
                arguments: arguments)
        }
    }

    /// Protocols 411–414 are one RSA + zlib format, so any of them decodes the others' files.
    private static func sameFormat(_ lhs: L2Protocol, _ rhs: L2Protocol) -> Bool {
        lhs == rhs || ((411...414).contains(lhs.rawValue) && (411...414).contains(rhs.rawValue))
    }

    private static func readHead(of file: URL) throws -> [UInt8] {
        do {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            return [UInt8](try handle.read(upToCount: HeaderSniffer.headerLength) ?? Data())
        } catch {
            throw L2CryptError.unreadableFile(file: file.path, reason: error.localizedDescription)
        }
    }
}
