import AppKit
import Darwin
import Foundation
import L2Crypt
import L2Dat
import Observation
import os

/// State of one editor window: the opened file, the editor text, the Program Log and the status bar.
/// Runs the open/save pipelines off the main actor and applies their results here.
@MainActor
@Observable
final class DocumentSession {
    enum State: Equatable {
        case idle
        /// An operation is running; the value is the step now running.
        case busy(String)
    }

    /// Status bar content.
    struct Status: Equatable {
        var message = "Open a .dat, .ini, .int or .htm file with Open & Decrypt (⌘O)"
        var isError = false
        var fileName: String?
        var recordCount: Int?
        var columnCount: Int?
        var elapsed: Duration?
        var detail: String?
    }

    /// An action that would discard unsaved edits and waits for confirmation.
    enum PendingAction: Equatable {
        case open
        case openURL(URL)
        case reopen
    }

    private(set) var state: State = .idle
    private(set) var openedFile: OpenedFile?
    /// The text last loaded into (or saved from) the editor; the live text is in the editor view.
    private(set) var text = ""
    /// Bumped whenever `text` must be loaded into the editor.
    private(set) var textRevision = 0
    var isDirty = false
    private(set) var log: [LogLine] = []
    private(set) var status = Status()
    private(set) var chronicles = Chronicles.load(datDefsOverride: nil)
    var isImporterPresented = false
    var pendingDiscard: PendingAction?

    /// Bridge to the AppKit text view (read on save, caret moves, find bar).
    @ObservationIgnored let editor = EditorController()
    @ObservationIgnored private var nextLogID = 0
    @ObservationIgnored private var started = false
    /// This window's own temp subfolder name (`<Temp folder>/<UUID>`).
    @ObservationIgnored private let tempSessionID = UUID()
    /// This window's temp subfolders (one per Temp folder setting used), removed on close when
    /// "delete temp on close" is on. Only these folders are ever removed, never a file by its name.
    @ObservationIgnored private var tempSessionDirs: Set<URL> = []
    /// The running Open/Save; closing the window cancels it and waits for it before removing temp files.
    @ObservationIgnored private var operation: Task<Void, Never>?
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    /// The user chose Don't Save in the close prompt.
    @ObservationIgnored var closeConfirmed = false
    /// The window showing this session (for the Save / Don't Save / Cancel sheet on quit).
    @ObservationIgnored weak var window: NSWindow?
    /// Save & Encrypt succeeded since the file was opened: later saves keep its `.bak` (the file as opened).
    @ObservationIgnored private var savedSinceOpen = false

    private static let logger = Logger(subsystem: "gr.blackthym.l2fileeditor", category: "session")

    var isBusy: Bool {
        if case .busy = state { return true }
        return false
    }

    /// Edits to an opened file that Save & Encrypt has not written yet.
    var hasUnsavedEdits: Bool { isDirty && openedFile != nil }

    /// The window is closing or closed: no operation starts any more.
    var isClosed: Bool { shutdownTask != nil }

    /// An empty, idle window that can take a file opened from Finder.
    var canTakeFile: Bool { !isClosed && !isBusy && openedFile == nil && !isDirty && pendingDiscard == nil }

    // MARK: - Lifecycle

    /// Loads the chronicle list and reports the DAT_defs folder and the helper in the log (once per window).
    func start() {
        guard !started else { return }
        started = true
        reloadChronicles()
        do {
            let helper = try L2CryptHelper.locate(overrides: AppSettings().helperOverrides)
            appendLog("l2encdec: \(helper.path)")
            Self.logger.notice("l2encdec helper: \(helper.path, privacy: .public)")
        } catch {
            fail(message: Self.describe(error))
            Self.logger.error("l2encdec helper: \(Self.describe(error), privacy: .public)")
        }
    }

    func reloadChronicles() {
        chronicles = Chronicles.load(datDefsOverride: AppSettings().datDefsOverrideURL)
        appendLog("DAT_defs: \(chronicles.datDefs.path) (\(chronicles.entries.count) chronicles)")
        for problem in chronicles.problems { appendLog(problem, level: .warning) }
    }

    /// Closes the session for good: no new operation starts, a running Open/Save is cancelled (its helper
    /// stopped) and awaited, and only then is the temp subfolder removed. Safe to call more than once; every
    /// caller waits for the same shutdown.
    func shutdown() async {
        if shutdownTask == nil {
            let running = operation
            running?.cancel()
            shutdownTask = Task {
                await running?.value
                cleanUpTemp()
                SessionRegistry.shared.unregister(self)
            }
        }
        await shutdownTask?.value
    }

    /// Waits until no Open/Save is running.
    func waitUntilIdle() async {
        await operation?.value
    }

    /// Removes this window's temp subfolder when the "delete temp on close" option is on: only a real folder
    /// (not a link) named after this window's UUID, at the place it resolves to now.
    private func cleanUpTemp() {
        guard AppSettings().deleteTempOnClose else { return }
        for dir in tempSessionDirs {
            guard let real = CanonicalPath.real(dir.path),
                  (real as NSString).lastPathComponent == tempSessionID.uuidString else { continue }
            var info = stat()
            guard lstat(real, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { continue }
            try? FileManager.default.removeItem(atPath: real)
        }
        tempSessionDirs.removeAll()
    }

    /// The Open dialog failed (the file cannot be read, or the panel itself failed).
    func reportImportFailure(_ error: Error) {
        fail(message: "cannot open the selected file: \(error.localizedDescription)")
    }

    // MARK: - Requests from the UI (confirm before discarding edits)

    func requestOpen() {
        guard !isBusy else { return }
        if isDirty { pendingDiscard = .open } else { isImporterPresented = true }
    }

    func requestOpen(_ url: URL) {
        guard !isBusy else { return }
        if isDirty { pendingDiscard = .openURL(url) } else { beginOpen(url) }
    }

    func requestReopen() {
        guard !isBusy, openedFile != nil else { return }
        if isDirty { pendingDiscard = .reopen } else { beginOpen(openedFile?.url) }
    }

    func confirmDiscard(_ action: PendingAction) {
        pendingDiscard = nil
        switch action {
        case .open: isImporterPresented = true
        case let .openURL(url): beginOpen(url)
        case .reopen: beginOpen(openedFile?.url)
        }
    }

    func requestSaveTxt() {
        guard !isBusy, let file = openedFile else { return }
        let suggested: String
        let encoding: TextCodec.Encoding
        switch file.kind {
        case .dat:
            suggested = file.temp.baseName + ".txt"
            encoding = .utf8(bom: false)
        case let .text(original):
            suggested = file.name
            encoding = original
        }
        guard let choice = SaveTxtPanel.run(suggestedName: suggested, encoding: encoding) else { return }
        Task { await saveTxt(to: choice.url, encoding: choice.encoding) }
    }

    // MARK: - Operations

    /// Starts Open & Decrypt with the current chronicle, text mode and float format (the session is busy
    /// when this returns); nil when an operation is running.
    @discardableResult
    func beginOpen(_ url: URL?) -> Task<Void, Never>? {
        guard let url, !isBusy, !isClosed else { return nil }
        let settings = AppSettings()
        let chronicle = settings.chronicle
        let tempDir = settings.tempDirectory
        tempSessionDirs.insert(TempLayout.sessionDir(base: tempDir, id: tempSessionID))
        let request = OpenPipeline.Request(
            source: url,
            tempDir: tempDir,
            sessionID: tempSessionID,
            schema: .folder(chronicles.folder(for: chronicle)),
            textMode: settings.textMode,
            floatFormat: settings.floatFormat,
            helperOverrides: settings.helperOverrides)
        let selected = L2Protocol(rawValue: settings.protocolVersion)
        let textModeTitle = settings.textMode.title
        return begin("Open & Decode", first: "Opening \(url.lastPathComponent)…") { report in
            report(.log("|  \(url.path)  [chronicle \(chronicle), \(textModeTitle)]", .info))
            let result = try await OpenPipeline.run(request, report: report)
            self.tempSessionDirs.insert(result.file.temp.dir)
            self.openedFile = result.file
            self.savedSinceOpen = false
            self.text = result.text
            self.textRevision += 1
            self.isDirty = false
            if let selected, selected != result.file.detectedProtocol {
                report(.log(
                    "|  note: the file is \(result.file.detectedProtocol.header); Save & Encrypt uses "
                        + "\(selected.header) (Version picker)", .warning))
            }
            self.status = Status(
                message: "Opened", fileName: result.file.name, recordCount: result.recordCount,
                columnCount: result.columnCount, elapsed: result.elapsed, detail: Self.detail(of: result.file))
        }
    }

    /// Save & Encrypt with the protocol of the Version picker.
    func saveAndEncrypt() async {
        guard !isBusy, !isClosed, let file = openedFile else { return }
        let settings = AppSettings()
        guard let target = L2Protocol(rawValue: settings.protocolVersion) else {
            fail(message: "unsupported protocol \(settings.protocolVersion) in the Version picker")
            return
        }
        let text = editor.currentText() ?? self.text
        let request = SavePipeline.Request(
            file: file, text: text, target: target, helperOverrides: settings.helperOverrides,
            keepExistingBackup: savedSinceOpen)
        let textMode = settings.textMode
        let floatFormat = settings.floatFormat
        let task = begin("Save & Encode", first: "Saving \(file.name)…") { report in
            if case .dat = file.kind, textMode != file.textMode {
                report(.log(
                    "|  note: the file was opened in \(file.textMode.title); Save & Encrypt keeps that mode "
                        + "(Text Mode picker: \(textMode.title), applies on ReOpen)", .warning))
            }
            if case .dat = file.kind, floatFormat != file.floatFormat {
                report(.log(
                    "|  note: the file was opened with \(file.floatFormat.title); the Float format picker "
                        + "(\(floatFormat.title)) applies on ReOpen", .warning))
            }
            let result = try await SavePipeline.run(request, report: report)
            self.savedSinceOpen = true
            self.text = text
            self.isDirty = false
            self.status = Status(
                message: "Saved (\(target.header), backup \(result.backup.lastPathComponent))",
                fileName: file.name, recordCount: result.rowCount ?? self.status.recordCount,
                columnCount: self.status.columnCount, elapsed: result.elapsed, detail: Self.detail(of: file))
        }
        await task?.value
    }

    /// Save TXT: writes the editor text to `url` with `encoding`.
    func saveTxt(to url: URL, encoding: TextCodec.Encoding) async {
        guard !isBusy, !isClosed, let file = openedFile else { return }
        let text = editor.currentText() ?? self.text
        let task = begin("Save TXT", first: "Writing \(url.lastPathComponent)…") { report in
            var timer = StepTimer()
            let bytes = try await SavePipeline.writeText(text, to: url, encoding: encoding)
            report(.log(
                "|  \(url.path), \(TextEncodingTitle.of(encoding)), \(bytes) bytes (\(StepTimer.format(timer.lap())))",
                .info))
            self.status = Status(
                message: "Saved TXT \(url.lastPathComponent)", fileName: file.name,
                recordCount: self.status.recordCount, columnCount: self.status.columnCount,
                elapsed: timer.total, detail: Self.detail(of: file))
        }
        await task?.value
    }

    /// Open Table: opens the temp `.txt` (with the current edits) in the default app, or reveals it.
    func openTable() {
        guard !isBusy, let file = openedFile else { return }
        let url = file.tableURL
        do {
            if isDirty, case .dat = file.kind, let text = editor.currentText() {
                try PipelineError.wrap("write", url) {
                    try Data(SavePipeline.lfBytes(text)).write(to: url, options: .atomic)
                }
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw PipelineError.fileSystem(action: "open", path: url.path, reason: "the temp file is gone; ReOpen the file")
            }
            if NSWorkspace.shared.open(url) {
                appendLog("Open Table: \(url.path)")
            } else {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                appendLog("Open Table: no app opens \(url.lastPathComponent); revealed it in Finder")
            }
        } catch {
            fail(error)
        }
    }

    func clearLog() {
        log.removeAll()
    }

    // MARK: - Running operations

    /// Starts `body` as one logged operation (busy state, `|-======== title {` … `} ========-` block,
    /// failures in the log and the status bar) and keeps its task so closing the window can cancel and
    /// await it. Nil when another operation is running or the window is closing.
    @discardableResult
    private func begin(
        _ title: String, first step: String, _ body: @escaping @MainActor (@escaping PipelineReporter) async throws -> Void
    ) -> Task<Void, Never>? {
        guard !isBusy, !isClosed else { return nil }
        state = .busy(step)
        appendLog("|-======== \(title) {")
        let reporter: PipelineReporter = { [weak self] event in self?.handle(event) }
        let task = Task {
            do {
                try await body(reporter)
            } catch {
                fail(error)
            }
            appendLog("} ========-")
            state = .idle
            operation = nil
        }
        operation = task
        return task
    }

    private func handle(_ event: PipelineEvent) {
        switch event {
        case let .step(step): state = .busy(step)
        case let .log(line, level): appendLog(line, level: level)
        }
    }

    private func fail(_ error: Error) {
        fail(message: Self.describe(error))
        if case let .txtFormat(line, column, _, _) = error as? L2DatError {
            editor.select(line: line, column: column)
        }
    }

    private func fail(message: String) {
        for line in message.split(separator: "\n", omittingEmptySubsequences: false) {
            appendLog("|  ERROR: \(line)", level: .error)
        }
        var failed = status
        failed.message = message.split(separator: "\n").first.map(String.init) ?? message
        failed.isError = true
        status = failed
        NSAccessibility.post(
            element: NSApplication.shared, notification: .announcementRequested,
            userInfo: [.announcement: failed.message, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func appendLog(_ text: String, level: LogLine.Level = .info) {
        log.append(LogLine(id: nextLogID, text: text, level: level))
        nextLogID += 1
    }

    private static func describe(_ error: Error) -> String {
        switch error {
        case let error as PipelineError: return error.description
        case let error as L2DatError: return error.description
        case let error as L2CryptError: return error.description
        default: return error.localizedDescription
        }
    }

    private static func detail(of file: OpenedFile) -> String {
        switch file.kind {
        case .dat: return file.detectedProtocol.header
        case let .text(encoding): return "\(file.detectedProtocol.header), \(TextEncodingTitle.of(encoding))"
        }
    }
}
