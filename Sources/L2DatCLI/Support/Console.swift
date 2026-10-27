import ArgumentParser
import Foundation
import L2Crypt
import L2Dat

/// stderr reporting shared by every subcommand.
enum Console {
    /// Runs a command body; any error other than an explicit `ExitCode` is printed on stderr as
    /// `error: <description>` and becomes exit status 1 (never a stack trace). An error caused by
    /// a signal handler stopping the helper is not reported: the signal ends the process.
    /// Installs the signal handlers first, before the body can create any temporary file.
    static func reportingErrors(_ body: () async throws -> Void) async throws {
        TemporaryFiles.installHandlers()
        do {
            try await body()
        } catch let exit as ExitCode {
            throw exit
        } catch {
            if TemporaryFiles.isStopping { TemporaryFiles.waitForSignalHandler() }
            self.error(describe(error))
            throw ExitCode.failure
        }
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case let error as L2DatError: return error.description
        case let error as L2CryptError: return error.description
        case let error as CLIError: return error.description
        default: return error.localizedDescription
        }
    }

    static func error(_ message: String) {
        write("error: \(message)\n")
    }

    static func warning(_ message: String) {
        write("warning: \(message)\n")
    }

    static func warn(_ warnings: [L2DatWarning]) {
        for warning in warnings {
            write("warning: \(warning)\n")
        }
    }

    private static func write(_ text: String) {
        FileHandle.standardError.write(Data(text.utf8))
    }
}
