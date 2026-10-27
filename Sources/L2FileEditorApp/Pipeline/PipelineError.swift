import Foundation

/// Failures of the app's own pipeline steps. L2Dat and L2Crypt errors pass through unchanged.
enum PipelineError: Error, Sendable, CustomStringConvertible {
    /// The chronicle has no DDF for this `.dat`.
    case ddfMissing(ddf: String, folder: String)
    /// The file has no `Lineage2Ver###` header, so it is not an encrypted client file.
    case notEncrypted(file: String)
    /// The disassembled text is not valid UTF-8 (strict decoding).
    case invalidText(file: String)
    /// A file-system step failed.
    case fileSystem(action: String, path: String, reason: String)
    /// The temp folder (or the temp copy) is the opened file or its folder, so working there would overwrite
    /// or delete the original.
    case tempFolderIsSourceFolder(path: String)
    /// The file is inside a window's temp subfolder (`<Temp folder>/<UUID>`), which that window deletes when
    /// it closes.
    case sourceInTempSession(path: String)
    /// A temp subfolder or temp file resolves (through a symlink) to a place outside the window's temp subfolder.
    case tempPathEscapes(path: String)
    /// The Temp folder of an opened file now resolves to another place (it was replaced by a link).
    case tempFolderChanged(path: String)
    /// `l2encdec` did not finish in time; it was stopped (with every process it started) and its partial output removed.
    case helperTimedOut(step: String, timeout: Duration)
    /// The operation was cancelled (the window closed or the app quit); `l2encdec` was stopped with every process it started.
    case cancelled(step: String)

    var description: String {
        switch self {
        case let .ddfMissing(ddf, folder):
            return "\(ddf) not found: check DDF files in folder \(folder) (or pick another chronicle)"
        case let .notEncrypted(file):
            return "\(file) is not an encrypted Lineage II file (no Lineage2Ver### header)"
        case let .invalidText(file):
            return "the disassembled text of \(file) is not valid UTF-8; try another text mode"
        case let .fileSystem(action, path, reason):
            return "cannot \(action) \(path): \(reason)"
        case let .tempFolderIsSourceFolder(path):
            return "the temp folder must not be the file's folder (\(path)); choose another folder in "
                + "Settings > Temp folder"
        case let .sourceInTempSession(path):
            return "\(path) is a temp file of an editor window and is deleted when that window closes; "
                + "open the original file instead"
        case let .tempPathEscapes(path):
            return "\(path) leads outside the temp folder (a symbolic link); remove it or choose another folder "
                + "in Settings > Temp folder"
        case let .tempFolderChanged(path):
            return "the temp folder \(path) was moved or replaced by a link since the file was opened; ReOpen the file"
        case let .helperTimedOut(step, timeout):
            return "l2encdec did not finish \(step) within \(timeout); it was stopped and its partial output "
                + "removed. Try again, or check the helper in Settings"
        case let .cancelled(step):
            return "\(step) was cancelled; l2encdec was stopped"
        }
    }

    /// Runs a file-system step, turning its Cocoa error into `.fileSystem`.
    static func wrap<T>(_ action: String, _ url: URL, _ body: () throws -> T) throws -> T {
        do {
            return try body()
        } catch {
            throw PipelineError.fileSystem(action: action, path: url.path, reason: error.localizedDescription)
        }
    }
}
