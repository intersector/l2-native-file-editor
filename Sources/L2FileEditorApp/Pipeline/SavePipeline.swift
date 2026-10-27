import Foundation
import L2Crypt
import L2Dat

/// Save & Encrypt: `.dat`: text → UTF-8 (LF) → assemble; text files: re-encode with the original
/// encoding/BOM → `l2encdec` encode → `<original>.bak` → replace the original.
///
/// Backup rule: `<original>.bak` holds the file as it was before the first Save & Encrypt since the window
/// opened it (Open or ReOpen). That first save replaces any older `.bak`; later saves from the same window
/// (`keepExistingBackup`) keep it, so a second save (e.g. one queued while another was in flight) never
/// replaces the original with an already-saved version. A missing `.bak` is always created.
enum SavePipeline {
    struct Request: Sendable {
        var file: OpenedFile
        var text: String
        /// Protocol to encrypt with (the Version picker).
        var target: L2Protocol
        /// How 8-bit strings are written back: the mode the file was opened with, never the live picker.
        var textMode: TextMode
        var helperOverrides: [URL]
        /// This window already saved this file since opening it: an existing `.bak` is kept.
        var keepExistingBackup = false
        var helperTimeout = HelperWatchdog.defaultTimeout
    }

    struct Result: Sendable {
        /// Rows assembled (`.dat` only).
        let rowCount: Int?
        let backup: URL
        /// The existing `.bak` was kept (see the backup rule).
        let backupKept: Bool
        let elapsed: Duration
    }

    @concurrent
    nonisolated static func run(_ request: Request, report: PipelineReporter) async throws -> Result {
        var timer = StepTimer()
        let file = request.file
        let temp = file.temp
        let fileManager = FileManager.default
        try temp.revalidate(source: file.url)

        var rowCount: Int?
        switch file.kind {
        case let .dat(schema):
            await report(.step("Assembling \(file.name)…"))
            let txt = lfBytes(request.text)
            let assembled = try Assembler.assemble(txt: txt, schema: schema, options: request.textMode.asmOptions)
            try PipelineError.wrap("write", temp.txt) { try Data(txt).write(to: temp.txt, options: .atomic) }
            try PipelineError.wrap("write", temp.decrypted) {
                try Data(assembled.dat).write(to: temp.decrypted, options: .atomic)
            }
            rowCount = assembled.rowCount
            await report(.log(
                "|  l2asm \(assembled.rowCount) rows -> dec-\(file.name), \(assembled.dat.count) bytes "
                    + "(\(StepTimer.format(timer.lap())))", .info))
            for event in PipelineEvent.warnings(assembled.warnings) { await report(event) }
        case let .text(encoding):
            await report(.step("Encoding text…"))
            let bytes = try TextCodec.encode(request.text, as: encoding)
            try PipelineError.wrap("write", temp.decrypted) {
                try Data(bytes).write(to: temp.decrypted, options: .atomic)
            }
            await report(.log(
                "|  text \(TextEncodingTitle.of(encoding)) -> dec-\(file.name), \(bytes.count) bytes "
                    + "(\(StepTimer.format(timer.lap())))", .info))
        }

        await report(.step("Encrypting \(file.name)…"))
        let codec = try L2Crypt(overrides: request.helperOverrides, timeout: request.helperTimeout)
        try await HelperWatchdog.run(step: "encrypting \(file.name)", output: temp.encrypted) {
            try await codec.encode(
                input: temp.decrypted, output: temp.encrypted, protocol: request.target, originalFileName: file.name)
        }
        let encrypted = try PipelineError.wrap("read", temp.encrypted) { try Data(contentsOf: temp.encrypted) }
        await report(.log(
            "|  l2encdec encode \(request.target.header) -> \(encrypted.count) bytes "
                + "(\(StepTimer.format(timer.lap())))", .info))

        await report(.step("Writing \(file.name)…"))
        let backup = file.url.appendingPathExtension("bak")
        let backupKept = request.keepExistingBackup && CanonicalPath.exists(backup.path)
        if !backupKept, fileManager.fileExists(atPath: file.url.path) {
            try PipelineError.wrap("back up", file.url) {
                if CanonicalPath.exists(backup.path) { try fileManager.removeItem(at: backup) }
                try fileManager.copyItem(at: file.url, to: backup)
            }
        }
        try PipelineError.wrap("write", file.url) { try encrypted.write(to: file.url, options: .atomic) }
        await report(.log(
            "|  backup \(backup.lastPathComponent)\(backupKept ? " kept (the file as opened)" : ""), saved "
                + "\(file.url.path) (\(StepTimer.format(timer.lap())))", .info))
        return Result(rowCount: rowCount, backup: backup, backupKept: backupKept, elapsed: timer.total)
    }

    /// Save TXT: writes `text` to `url` with `encoding` (and its BOM).
    @concurrent
    nonisolated static func writeText(_ text: String, to url: URL, encoding: TextCodec.Encoding) async throws -> Int {
        let bytes = try TextCodec.encode(text, as: encoding)
        try PipelineError.wrap("write", url) { try Data(bytes).write(to: url, options: .atomic) }
        return bytes.count
    }

    /// UTF-8 bytes of `text` with CRLF and lone CR turned into LF (one pass over the bytes).
    static func lfBytes(_ text: String) -> [UInt8] {
        var bytes = Array(text.utf8)
        guard bytes.contains(0x0D) else { return bytes }
        var write = 0
        var read = 0
        while read < bytes.count {
            let byte = bytes[read]
            read += 1
            if byte == 0x0D {
                if read < bytes.count, bytes[read] == 0x0A { continue }
                bytes[write] = 0x0A
            } else {
                bytes[write] = byte
            }
            write += 1
        }
        bytes.removeSubrange(write...)
        return bytes
    }
}

extension SavePipeline.Request {
    /// A request that writes with the text mode `file` was opened with.
    init(
        file: OpenedFile, text: String, target: L2Protocol, helperOverrides: [URL], keepExistingBackup: Bool = false
    ) {
        self.init(
            file: file, text: text, target: target, textMode: file.textMode, helperOverrides: helperOverrides,
            keepExistingBackup: keepExistingBackup)
    }
}
