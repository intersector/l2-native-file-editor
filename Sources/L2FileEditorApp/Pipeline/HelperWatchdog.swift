import Foundation
import L2Crypt

/// Runs one `l2encdec` call for a pipeline step. The time limit and cancellation live in L2Crypt, which stops
/// the helper with its whole process group (`L2Crypt(timeout:)`); this maps those stops to the pipeline's
/// errors and removes the partial output.
enum HelperWatchdog {
    /// Time limit of one `l2encdec` call. DEBUG builds read `debugHelperTimeoutSeconds` from the defaults
    /// (e.g. `-debugHelperTimeoutSeconds 5` on the command line) to test the timeout path.
    static var defaultTimeout: Duration {
        #if DEBUG
        let seconds = UserDefaults.standard.double(forKey: "debugHelperTimeoutSeconds")
        if seconds > 0 { return .milliseconds(Int64(seconds * 1000)) }
        #endif
        return .seconds(120)
    }

    /// - Parameters:
    ///   - step: What the helper does, for the error ("decrypting x.dat").
    ///   - output: The helper's output file; a leftover is removed first, so the helper never writes through
    ///     a link planted there, and a partial one is removed after a stop.
    nonisolated static func run<T: Sendable>(
        step: String, output: URL, _ operation: @Sendable () async throws -> T
    ) async throws -> T {
        if CanonicalPath.exists(output.path) {
            try PipelineError.wrap("remove", output) { try FileManager.default.removeItem(at: output) }
        }
        do {
            return try await operation()
        } catch let L2CryptError.timedOut(_, timeout) {
            try? FileManager.default.removeItem(at: output)
            throw PipelineError.helperTimedOut(step: step, timeout: timeout)
        } catch L2CryptError.cancelled {
            try? FileManager.default.removeItem(at: output)
            throw PipelineError.cancelled(step: step)
        }
    }
}
