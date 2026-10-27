#if DEBUG
import Darwin
import Foundation
import L2Crypt
import L2Dat

/// `L2FileEditor --selftest <file.dat> <file.ddf>`: open → edit one cell → save → verify, through the
/// same pipeline functions the app uses. `L2FileEditor --selftest <file.ini|int|htm>`: open → save
/// unedited → verify the text round trip. Works on a scratch copy; prints PASS or FAIL and returns
/// the exit code.
@MainActor
enum SelfTest {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run(_ arguments: [String]) async -> Int32 {
        guard let first = arguments.first, arguments.count <= 2 else {
            print("usage: L2FileEditor --selftest <file.dat> <file.ddf> | --selftest <file.ini>")
            return 2
        }
        let source = URL(fileURLWithPath: first)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("L2FileEditor-selftest-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do {
            let work = scratch.appendingPathComponent("work", isDirectory: true)
            try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
            let copy = work.appendingPathComponent(source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copy)
            if arguments.count == 2 {
                try await runDat(copy, ddf: URL(fileURLWithPath: arguments[1]), scratch: scratch)
            } else {
                try await runText(copy, scratch: scratch)
            }
            print("PASS")
            return 0
        } catch {
            print("FAIL: \(error)")
            return 1
        }
    }

    private static let printer: PipelineReporter = { event in
        if case let .log(line, _) = event { print(line) }
    }

    private static func open(
        _ file: URL, ddf: URL?, temp: URL, session: UUID = UUID()
    ) async throws -> OpenPipeline.Result {
        print("|-======== Open & Decode {")
        defer { print("} ========-") }
        let request = OpenPipeline.Request(
            source: file, tempDir: temp, sessionID: session, schema: .file(ddf ?? file), textMode: .default,
            floatFormat: .f, helperOverrides: [])
        return try await OpenPipeline.run(request, report: printer)
    }

    private static func save(
        _ file: OpenedFile, text: String, keepExistingBackup: Bool = false
    ) async throws -> SavePipeline.Result {
        print("|-======== Save & Encode {")
        defer { print("} ========-") }
        let request = SavePipeline.Request(
            file: file, text: text, target: file.detectedProtocol, helperOverrides: [],
            keepExistingBackup: keepExistingBackup)
        return try await SavePipeline.run(request, report: printer)
    }

    /// A copy of `original` in its own fresh folder under `scratch`.
    private static func scratchCopy(of original: URL, named folder: String, scratch: URL) throws -> URL {
        let directory = scratch.appendingPathComponent(folder, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent(original.lastPathComponent)
        try FileManager.default.copyItem(at: original, to: copy)
        return copy
    }

    private static func listing(_ folder: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    }

    /// Opening with a temp folder that is the file's folder (directly, through a symlink, or the window's own
    /// temp subfolder) must throw `.tempFolderIsSourceFolder`, opening a file inside another window's temp
    /// subfolder must throw `.sourceInTempSession`, and both leave the file and its folder untouched.
    private static func runTempGuards(_ original: URL, ddf: URL?, scratch: URL) async throws {
        let copy = try scratchCopy(of: original, named: "guard-src", scratch: scratch)
        let folder = copy.deletingLastPathComponent()
        let bytes = try Data(contentsOf: copy)
        let before = try listing(folder)

        let link = scratch.appendingPathComponent("guard-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        for (label, temp) in [("the file's folder", folder), ("a symlink to the file's folder", link)] {
            do {
                _ = try await open(copy, ddf: ddf, temp: temp)
                throw Failure(description: "opening with the temp folder = \(label) did not fail")
            } catch let PipelineError.tempFolderIsSourceFolder(path) {
                print("guard: temp folder = \(label) rejected (\(path))")
            }
        }

        let base = scratch.appendingPathComponent("guard-temp", isDirectory: true)
        let session = UUID()
        let opened = try await open(copy, ddf: ddf, temp: base, session: session)
        let tempCopy = opened.file.temp.copy
        do {
            _ = try await open(tempCopy, ddf: ddf, temp: base, session: session)
            throw Failure(description: "opening the window's own temp copy did not fail")
        } catch let PipelineError.tempFolderIsSourceFolder(path) {
            print("guard: file inside the window's temp subfolder rejected (\(path))")
        }
        do {
            _ = try await open(tempCopy, ddf: ddf, temp: base, session: UUID())
            throw Failure(description: "opening another window's temp copy did not fail")
        } catch let PipelineError.sourceInTempSession(path) {
            print("guard: file inside another window's temp subfolder rejected (\(path))")
        }
        guard FileManager.default.fileExists(atPath: tempCopy.path) else {
            throw Failure(description: "a rejected open removed the temp copy")
        }
        guard try Data(contentsOf: copy) == bytes, try listing(folder) == before else {
            throw Failure(description: "a rejected open changed the file or its folder")
        }
        print("guard: the file and its folder are unchanged after every rejected open")
    }

    /// Temp containment, each case resolving both sides with `realpath`: a symlinked Temp folder works for
    /// open and save; a temp file that is a link out of the window's subfolder is rejected on Save, a
    /// subfolder that is a link out of the Temp folder is rejected on Open, a Temp folder deleted after Open
    /// is recreated by Save, and one replaced by a link is rejected; nothing outside is written.
    private static func runTempContainment(_ original: URL, ddf: URL?, scratch: URL) async throws {
        let fileManager = FileManager.default
        let copy = try scratchCopy(of: original, named: "contain-src", scratch: scratch)
        let outside = scratch.appendingPathComponent("contain-outside", isDirectory: true)
        try fileManager.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.bin")
        try Data("victim".utf8).write(to: victim)

        let real = scratch.appendingPathComponent("contain-real", isDirectory: true)
        try fileManager.createDirectory(at: real, withIntermediateDirectories: true)
        let link = scratch.appendingPathComponent("contain-link", isDirectory: true)
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)
        let opened = try await open(copy, ddf: ddf, temp: link)
        let temp = opened.file.temp
        guard let realPath = CanonicalPath.real(real.path),
              CanonicalPath.components(temp.dir.path) == CanonicalPath.components(realPath) + [temp.dir.lastPathComponent],
              fileManager.fileExists(atPath: temp.copy.path) else {
            throw Failure(description: "the symlinked temp folder did not resolve to \(real.path) (\(temp.dir.path))")
        }
        _ = try await save(opened.file, text: opened.text)
        print("contain: symlinked temp folder \(link.lastPathComponent) resolved to \(temp.dir.path); open and save ran there")

        let saved = try Data(contentsOf: copy)
        if CanonicalPath.exists(temp.encrypted.path) { try fileManager.removeItem(at: temp.encrypted) }
        try fileManager.createSymbolicLink(at: temp.encrypted, withDestinationURL: victim)
        do {
            _ = try await save(opened.file, text: opened.text)
            throw Failure(description: "a save whose temp output links out of the temp folder did not fail")
        } catch let PipelineError.tempPathEscapes(path) {
            print("contain: temp output linked out of the temp folder rejected (\(path))")
        }
        guard try Data(contentsOf: victim) == Data("victim".utf8), try Data(contentsOf: copy) == saved else {
            throw Failure(description: "a rejected save wrote outside the temp folder or changed the file")
        }

        let uuidBase = scratch.appendingPathComponent("contain-uuid", isDirectory: true)
        try fileManager.createDirectory(at: uuidBase, withIntermediateDirectories: true)
        let session = UUID()
        try fileManager.createSymbolicLink(
            at: TempLayout.sessionDir(base: uuidBase, id: session), withDestinationURL: outside)
        do {
            _ = try await open(copy, ddf: ddf, temp: uuidBase, session: session)
            throw Failure(description: "opening with a window subfolder that links out of the temp folder did not fail")
        } catch let PipelineError.tempPathEscapes(path) {
            print("contain: window subfolder linked out of the temp folder rejected (\(path))")
        }
        guard try listing(outside) == ["victim.bin"] else {
            throw Failure(description: "a rejected open wrote outside the temp folder")
        }

        let deleted = scratch.appendingPathComponent("contain-deleted", isDirectory: true)
        let reopened = try await open(copy, ddf: ddf, temp: deleted)
        try fileManager.removeItem(at: deleted)
        _ = try await save(reopened.file, text: reopened.text)
        guard fileManager.fileExists(atPath: reopened.file.temp.decrypted.path) else {
            throw Failure(description: "Save did not recreate the deleted temp folder")
        }
        print("contain: temp folder deleted after open was recreated by Save")

        let replaced = scratch.appendingPathComponent("contain-replaced", isDirectory: true)
        let elsewhere = scratch.appendingPathComponent("contain-elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let third = try await open(copy, ddf: ddf, temp: replaced)
        try fileManager.removeItem(at: replaced)
        try fileManager.createSymbolicLink(at: replaced, withDestinationURL: elsewhere)
        do {
            _ = try await save(third.file, text: third.text)
            throw Failure(description: "a save after the temp folder was replaced by a link did not fail")
        } catch let PipelineError.tempFolderChanged(path) {
            print("contain: temp folder replaced by a link after open rejected (\(path))")
        }
        guard try listing(elsewhere).isEmpty else {
            throw Failure(description: "a rejected save wrote into the folder the replaced temp folder links to")
        }
    }

    /// A `#!/bin/sh` helper whose `sleep 600` child keeps the output pipes open is stopped after the time
    /// limit, and one running when the task is cancelled is stopped at once: both within about two seconds,
    /// with no process of the helper's group left (the `sleep` included) and no partial output behind.
    private static func runHelperStops(_ original: URL, scratch: URL) async throws {
        let fileManager = FileManager.default
        let copy = try scratchCopy(of: original, named: "stop-src", scratch: scratch)
        let base = scratch.appendingPathComponent("stop-temp", isDirectory: true)
        let clock = ContinuousClock()

        /// The hanging helper of one case; it writes its pid (its process group id) to `<label>.pid` first.
        func hangingHelper(_ label: String) throws -> (helper: URL, pidFile: URL) {
            let pidFile = scratch.appendingPathComponent("\(label).pid")
            let helper = scratch.appendingPathComponent("hanging-l2encdec-\(label)")
            try Data("#!/bin/sh\necho $$ > '\(pidFile.path)'\nsleep 600\n".utf8).write(to: helper)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: helper.path)
            return (helper, pidFile)
        }
        func request(_ session: UUID, helper: URL, timeout: Duration) -> OpenPipeline.Request {
            OpenPipeline.Request(
                source: copy, tempDir: base, sessionID: session, schema: .file(copy), textMode: .default,
                floatFormat: .f, helperOverrides: [helper], helperTimeout: timeout)
        }
        func checkStopped(_ session: UUID, pidFile: URL, _ label: String, _ elapsed: Duration) async throws {
            let text = try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let group = pid_t(text) else { throw Failure(description: "\(label): no helper pid") }
            var alive = true
            for _ in 0..<40 {
                alive = !(killpg(group, 0) != 0 && errno == ESRCH)
                if !alive { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard !alive else {
                throw Failure(description: "\(label): process group \(group) of the helper is still running")
            }
            guard let realBase = CanonicalPath.real(base.path) else { throw Failure(description: "no temp folder") }
            let layout = TempLayout(
                base: URL(fileURLWithPath: realBase),
                dir: TempLayout.sessionDir(base: URL(fileURLWithPath: realBase), id: session),
                fileName: copy.lastPathComponent)
            guard !CanonicalPath.exists(layout.decrypted.path) else {
                throw Failure(description: "\(label): the partial output was left behind")
            }
            guard elapsed < .milliseconds(2500) else { throw Failure(description: "\(label): took \(elapsed)") }
            print("stop: \(label) after \(StepTimer.format(elapsed)); process group \(group) gone (sh and its sleep), "
                + "no partial output")
        }

        let timedOut = UUID()
        let slow = try hangingHelper("timeout")
        let start = clock.now
        do {
            _ = try await OpenPipeline.run(request(timedOut, helper: slow.helper, timeout: .seconds(1)), report: { _ in })
            throw Failure(description: "a hanging helper did not time out")
        } catch let error as PipelineError {
            guard case .helperTimedOut = error else { throw error }
            print("stop: \(error)")
        }
        try await checkStopped(timedOut, pidFile: slow.pidFile, "timed out (limit 1 s)", clock.now - start)

        let cancelled = UUID()
        let stuck = try hangingHelper("cancel")
        let task = Task {
            try await OpenPipeline.run(request(cancelled, helper: stuck.helper, timeout: .seconds(60)), report: { _ in })
        }
        for _ in 0..<500 where !fileManager.fileExists(atPath: stuck.pidFile.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let cancelStart = clock.now
        task.cancel()
        do {
            _ = try await task.value
            throw Failure(description: "cancelling a running helper did not stop the open")
        } catch let error as PipelineError {
            guard case .cancelled = error else { throw error }
            print("stop: \(error)")
        }
        try await checkStopped(cancelled, pidFile: stuck.pidFile, "cancelled", clock.now - cancelStart)
    }

    /// Open in Default mode, flip the Text Mode picker to UTF-8, save without editing: the decrypted bytes
    /// must equal the decrypted bytes read at open. The picker is not an input of Save & Encrypt any more;
    /// the control shows what reading it at save time would have done.
    private static func runModeConsistency(_ original: URL, ddf: URL, scratch: URL) async throws {
        let copy = try scratchCopy(of: original, named: "mode-src", scratch: scratch)
        let opened = try await open(copy, ddf: ddf, temp: scratch.appendingPathComponent("mode"))
        guard opened.file.textMode == .default else { throw Failure(description: "the file did not record its text mode") }
        let plain = try Data(contentsOf: opened.file.temp.decrypted)
        let picker = TextMode.utf8

        _ = try await save(opened.file, text: opened.text)
        let kept = try Data(contentsOf: opened.file.temp.decrypted)
        guard kept == plain else {
            throw Failure(description: "an unedited save changed the decrypted bytes (\(plain.count) vs \(kept.count))")
        }
        print("mode: opened in \(opened.file.textMode.title), picker now \(picker.title): decrypted bytes identical "
            + "after an unedited save (\(plain.count) bytes)")

        let live = SavePipeline.Request(
            file: opened.file, text: opened.text, target: opened.file.detectedProtocol, textMode: picker,
            helperOverrides: [])
        _ = try await SavePipeline.run(live, report: { _ in })
        let changed = try Data(contentsOf: opened.file.temp.decrypted) != plain
        print("mode control: saving with the picker value would "
            + (changed ? "have changed the file" : "not differ here (no 8-bit strings in this file)"))
    }

    private static func runDat(_ copy: URL, ddf: URL, scratch: URL) async throws {
        try await runTempGuards(copy, ddf: ddf, scratch: scratch)
        try await runTempContainment(copy, ddf: ddf, scratch: scratch)
        try await runHelperStops(copy, scratch: scratch)
        try await runModeConsistency(copy, ddf: ddf, scratch: scratch)
        let original = try Data(contentsOf: copy)
        let opened = try await open(copy, ddf: ddf, temp: scratch.appendingPathComponent("open"))
        print("open: \(opened.recordCount ?? 0) records, \(opened.columnCount ?? 0) columns in "
            + StepTimer.format(opened.elapsed))
        guard case .dat = opened.file.kind else { throw Failure(description: "the file did not open as a table") }

        let edit = try editOneCell(opened.text)
        print("edit: line \(edit.line), cell \(edit.cell): \(edit.old) -> \(edit.new)")

        // A broken ASCF cell (unknown hint) must fail with its txt line and leave the original untouched.
        if edit.kind == .ascf {
            let broken = try replaceCell(opened.text, line: edit.line, cell: edit.cell, with: "z," + edit.new.dropFirst(2))
            do {
                _ = try await save(opened.file, text: broken)
                throw Failure(description: "saving a broken cell did not fail")
            } catch let L2DatError.txtFormat(line, column, field, _) {
                print("broken cell rejected at txt line \(line), column \(column), field \(field ?? "?")")
                guard line == edit.line else { throw Failure(description: "error line \(line), expected \(edit.line)") }
            }
            guard try Data(contentsOf: copy) == original else {
                throw Failure(description: "a failed save modified the original file")
            }
        }

        _ = try await save(opened.file, text: edit.text)
        let backup = copy.appendingPathExtension("bak")
        guard try Data(contentsOf: backup) == original else {
            throw Failure(description: "\(backup.lastPathComponent) is not the original file")
        }
        print("backup: \(backup.lastPathComponent) equals the original")

        // A second save from the same window keeps the .bak of the file as opened.
        let second = try await save(opened.file, text: edit.text, keepExistingBackup: true)
        guard second.backupKept, try Data(contentsOf: backup) == original else {
            throw Failure(description: "a second save replaced \(backup.lastPathComponent)")
        }
        print("backup: a second save kept \(backup.lastPathComponent) (still the original)")

        let reopened = try await open(copy, ddf: ddf, temp: scratch.appendingPathComponent("verify"))
        let differences = cellDifferences(opened.text, reopened.text)
        guard differences.count == 1, let only = differences.first,
              only.line == edit.line, only.cell == edit.cell, only.new == edit.new else {
            throw Failure(description: "expected one changed cell, found \(differences.count): "
                + differences.prefix(5).map { "line \($0.line) cell \($0.cell): \($0.old) -> \($0.new)" }
                    .joined(separator: "; "))
        }
        guard reopened.text == edit.text else { throw Failure(description: "re-opened text differs from the edit") }
        print("verify: decode + disasm of the saved file differs from the original only in line \(only.line), "
            + "cell \(only.cell)")
    }

    private static func runText(_ copy: URL, scratch: URL) async throws {
        try await runTempGuards(copy, ddf: nil, scratch: scratch)
        try await runTempContainment(copy, ddf: nil, scratch: scratch)
        try await runHelperStops(copy, scratch: scratch)
        let original = try Data(contentsOf: copy)
        let opened = try await open(copy, ddf: nil, temp: scratch.appendingPathComponent("open"))
        guard case let .text(encoding) = opened.file.kind else {
            throw Failure(description: "the file did not open as text")
        }
        let plain = try Data(contentsOf: opened.file.temp.decrypted)
        print("open: \(TextEncodingTitle.of(encoding)), \(opened.text.utf16.count) characters in "
            + StepTimer.format(opened.elapsed))

        _ = try await save(opened.file, text: opened.text)
        guard try Data(contentsOf: copy.appendingPathExtension("bak")) == original else {
            throw Failure(description: "the backup is not the original file")
        }
        let reopened = try await open(copy, ddf: nil, temp: scratch.appendingPathComponent("verify"))
        let replain = try Data(contentsOf: reopened.file.temp.decrypted)
        guard replain == plain else {
            throw Failure(description: "decrypted bytes differ after an unedited save (\(plain.count) vs \(replain.count))")
        }
        print("verify: decrypted bytes identical after an unedited save (\(plain.count) bytes, "
            + "\(TextEncodingTitle.of(encoding)))")
        let encryptedSame = try Data(contentsOf: copy) == original
        print("encrypted file byte-identical to the original: \(encryptedSame ? "yes" : "no (re-compressed)")")
    }

    // MARK: - Cells

    private struct Edit {
        let text: String
        let line: Int
        let cell: Int
        let old: String
        let new: String
        let kind: CellKind
    }

    private struct Difference {
        let line: Int
        let cell: Int
        let old: String
        let new: String
    }

    private static func lines(_ text: String) -> [ArraySlice<UInt8>] {
        Array(text.utf8).split(separator: 0x0A, omittingEmptySubsequences: false)
    }

    private static func cells(_ line: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        line.split(separator: 0x09, omittingEmptySubsequences: false)
    }

    /// Changes the first cell after the header that is, in order of preference, an ASCF string
    /// (`a,`/`u,`: an `X` after the prefix), a FLOAT (`1.50000000`) or UNICODE-like text (lower-case
    /// letters: an `X` appended). Numbers that could be counters or ENBBY references are never touched.
    private static func editOneCell(_ text: String) throws -> Edit {
        let all = lines(text)
        for kind in CellKind.allCases {
            for lineIndex in all.indices.dropFirst() {
                for (cellIndex, cell) in cells(all[lineIndex]).enumerated() where kind.matches(cell) {
                    let old = String(decoding: cell, as: UTF8.self)
                    let new: String
                    switch kind {
                    case .ascf: new = String(old.prefix(2)) + "X" + old.dropFirst(2)
                    case .float: new = old == "1.50000000" ? "2.50000000" : "1.50000000"
                    case .text: new = old + "X"
                    }
                    let edited = try replaceCell(text, line: lineIndex + 1, cell: cellIndex + 1, with: new)
                    return Edit(text: edited, line: lineIndex + 1, cell: cellIndex + 1, old: old, new: new, kind: kind)
                }
            }
        }
        throw Failure(description: "no string, float or text cell to edit")
    }

    private enum CellKind: CaseIterable {
        case ascf
        case float
        case text

        func matches(_ cell: ArraySlice<UInt8>) -> Bool {
            switch self {
            case .ascf:
                return cell.count >= 2 && (cell.first == UInt8(ascii: "a") || cell.first == UInt8(ascii: "u"))
                    && cell[cell.startIndex + 1] == UInt8(ascii: ",")
            case .float:
                guard let dot = cell.firstIndex(of: UInt8(ascii: ".")), cell.endIndex - dot == 9 else { return false }
                return cell.allSatisfy {
                    $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") || (0x30...0x39).contains($0)
                }
            case .text:
                return !cell.starts(with: Array("NaN(".utf8)) && cell.contains { (0x61...0x7A).contains($0) }
            }
        }
    }

    /// `text` with cell `cell` (1-based) of line `line` (1-based) replaced.
    private static func replaceCell(_ text: String, line: Int, cell: Int, with value: String) throws -> String {
        var all = lines(text)
        var row = cells(all[line - 1])
        guard cell - 1 < row.count else { throw Failure(description: "line \(line) has no cell \(cell)") }
        row[cell - 1] = ArraySlice(value.utf8)
        all[line - 1] = ArraySlice(Array(row.joined(separator: [0x09])))
        return String(decoding: Array(all.joined(separator: [0x0A])), as: UTF8.self)
    }

    private static func cellDifferences(_ lhs: String, _ rhs: String) -> [Difference] {
        let left = lines(lhs)
        let right = lines(rhs)
        var result: [Difference] = []
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? cells(left[index]) : []
            let b = index < right.count ? cells(right[index]) : []
            for cell in 0..<max(a.count, b.count) {
                let old = cell < a.count ? a[cell] : []
                let new = cell < b.count ? b[cell] : []
                if !old.elementsEqual(new) {
                    result.append(Difference(
                        line: index + 1, cell: cell + 1,
                        old: String(decoding: old, as: UTF8.self), new: String(decoding: new, as: UTF8.self)))
                }
            }
        }
        return result
    }
}
#endif
