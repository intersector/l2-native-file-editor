import Foundation
import L2Crypt
import L2Dat

/// Open & Decrypt: copy to temp → `l2encdec` decode → `.dat`: DDF + disassemble; other files: text decode.
enum OpenPipeline {
    /// Where the DDF of a `.dat` comes from.
    enum SchemaSource: Sendable {
        /// A chronicle folder holding `<name>.ddf`.
        case folder(URL)
        /// One DDF file, whatever its name.
        case file(URL)
    }

    struct Request: Sendable {
        var source: URL
        /// The Temp folder setting; the window's files live in `<tempDir>/<sessionID>`.
        var tempDir: URL
        var sessionID: UUID
        var schema: SchemaSource
        var textMode: TextMode
        var floatFormat: FloatFormat
        var helperOverrides: [URL]
        var helperTimeout = HelperWatchdog.defaultTimeout
    }

    struct Result: Sendable {
        let file: OpenedFile
        let text: String
        /// Records and columns of a `.dat` table; nil for text files.
        let recordCount: Int?
        let columnCount: Int?
        let elapsed: Duration
    }

    @concurrent
    nonisolated static func run(_ request: Request, report: PipelineReporter) async throws -> Result {
        var timer = StepTimer()
        let name = request.source.lastPathComponent
        let temp = try TempLayout.prepare(
            base: request.tempDir, id: request.sessionID, fileName: name, source: request.source)
        let fileManager = FileManager.default

        await report(.step("Copying \(name)…"))
        try PipelineError.wrap("copy to temp", request.source) {
            if fileManager.fileExists(atPath: temp.copy.path) { try fileManager.removeItem(at: temp.copy) }
            try fileManager.copyItem(at: request.source, to: temp.copy)
        }
        await report(.log("|  copy \(name) -> \(temp.dir.path) (\(StepTimer.format(timer.lap())))", .info))

        await report(.step("Decrypting \(name)…"))
        let codec = try L2Crypt(overrides: request.helperOverrides, timeout: request.helperTimeout)
        let detected: L2Protocol
        do {
            detected = try await HelperWatchdog.run(step: "decrypting \(name)", output: temp.decrypted) {
                try await codec.decode(input: temp.copy, output: temp.decrypted, protocol: nil, originalFileName: name)
            }
        } catch L2CryptError.unrecognizedHeader {
            throw PipelineError.notEncrypted(file: name)
        }
        let decrypted = try PipelineError.wrap("read", temp.decrypted) {
            [UInt8](try Data(contentsOf: temp.decrypted))
        }
        await report(.log(
            "|  l2encdec decode \(detected.header) -> dec-\(name), \(decrypted.count) bytes "
                + "(\(StepTimer.format(timer.lap())))", .info))

        guard OpenedFile.isDat(request.source) else {
            await report(.step("Decoding text…"))
            let decoded = try TextCodec.decode(decrypted)
            await report(.log(
                "|  text \(TextEncodingTitle.of(decoded.encoding)), \(decoded.text.utf16.count) characters "
                    + "(\(StepTimer.format(timer.lap())))", .info))
            let file = OpenedFile(
                url: request.source, kind: .text(decoded.encoding), detectedProtocol: detected, temp: temp,
                textMode: request.textMode, floatFormat: request.floatFormat)
            return Result(file: file, text: decoded.text, recordCount: nil, columnCount: nil, elapsed: timer.total)
        }

        await report(.step("Loading DDF…"))
        let ddfURL = try locateDDF(for: name, in: request.schema)
        let ddfBytes = try PipelineError.wrap("read", ddfURL) { [UInt8](try Data(contentsOf: ddfURL)) }
        let schema = try Schema(DDF.parse(ddfBytes, fileName: ddfURL.lastPathComponent))
        await report(.log("|  ddf \(ddfURL.path) (\(StepTimer.format(timer.lap())))", .info))

        await report(.step("Disassembling \(name)…"))
        let disasm = try Disassembler.run(
            dat: decrypted, schema: schema, options: request.textMode.disasmOptions(floatFormat: request.floatFormat))
        let columns = columnCount(disasm.txt, separator: disasm.schema.controls.fs)
        await report(.log(
            "|  l2disasm \(disasm.recordCount) records, \(columns) columns, \(disasm.txt.count) bytes "
                + "(\(StepTimer.format(timer.lap())))", .info))
        for event in PipelineEvent.warnings(disasm.warnings) { await report(event) }

        await report(.step("Writing temp files…"))
        try PipelineError.wrap("write", temp.txt) { try Data(disasm.txt).write(to: temp.txt, options: .atomic) }
        try PipelineError.wrap("write", temp.newDDF) {
            try Data(DDF.export(disasm.schema)).write(to: temp.newDDF, options: .atomic)
        }
        guard let text = String(bytes: disasm.txt, encoding: .utf8) else {
            throw PipelineError.invalidText(file: name)
        }
        await report(.log(
            "|  wrote \(temp.txt.lastPathComponent), \(temp.newDDF.lastPathComponent) "
                + "(\(StepTimer.format(timer.lap())))", .info))

        let file = OpenedFile(
            url: request.source, kind: .dat(disasm.schema), detectedProtocol: detected, temp: temp,
            textMode: request.textMode, floatFormat: request.floatFormat)
        return Result(
            file: file, text: text, recordCount: disasm.recordCount, columnCount: columns, elapsed: timer.total)
    }

    /// `<folder>/<base>.ddf`, matched case-insensitively when the volume is case-sensitive.
    private static func locateDDF(for fileName: String, in source: SchemaSource) throws -> URL {
        switch source {
        case let .file(url):
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PipelineError.ddfMissing(ddf: url.lastPathComponent, folder: url.deletingLastPathComponent().path)
            }
            return url
        case let .folder(folder):
            let ddfName = (fileName as NSString).deletingPathExtension + ".ddf"
            let direct = folder.appendingPathComponent(ddfName)
            if FileManager.default.fileExists(atPath: direct.path) { return direct }
            let lowered = ddfName.lowercased()
            if let match = try? FileManager.default.contentsOfDirectory(atPath: folder.path)
                .first(where: { $0.lowercased() == lowered }) {
                return folder.appendingPathComponent(match)
            }
            throw PipelineError.ddfMissing(ddf: ddfName, folder: folder.path)
        }
    }

    /// Cells in the first line (the header when present).
    private static func columnCount(_ txt: [UInt8], separator: [UInt8]) -> Int {
        guard !txt.isEmpty, let first = separator.first else { return 0 }
        let lineEnd = txt.firstIndex(of: 0x0A) ?? txt.endIndex
        var count = 1
        var index = 0
        while index < lineEnd {
            if txt[index] == first, index + separator.count <= lineEnd,
               txt[index..<(index + separator.count)].elementsEqual(separator) {
                count += 1
                index += separator.count
            } else {
                index += 1
            }
        }
        return count
    }
}
