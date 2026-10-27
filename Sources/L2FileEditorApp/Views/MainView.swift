import AppKit
import L2Crypt
import SwiftUI
import UniformTypeIdentifiers

/// The editor window: toolbar (actions and the chronicle/version/text-mode pickers), the editor above
/// the Program Log, and the status bar.
struct MainView: View {
    @State private var session = DocumentSession()
    @Environment(\.openWindow) private var openWindow
    private var settings = AppSettings()

    /// Open dialog filter: `All Formats (dat,ini,int,htm)` plus TXT.
    private static let openTypes: [UTType] = ["dat", "ini", "int", "htm", "html", "txt"]
        .compactMap { UTType(filenameExtension: $0) }

    var body: some View {
        VStack(spacing: 0) {
            VSplitView {
                EditorTextView(session: session)
                    .frame(minHeight: 160, idealHeight: 520)
                    .accessibilityLabel("Editor")
                if settings.showLog {
                    LogView(session: session)
                        .frame(minHeight: 70, idealHeight: 150, maxHeight: 400)
                }
            }
            Divider()
            StatusBarView(session: session)
        }
        .frame(minWidth: 760, minHeight: 480)
        .toolbar { toolbarContent }
        .toolbar(settings.showToolbar ? .visible : .hidden, for: .windowToolbar)
        .navigationTitle(session.openedFile?.name ?? "L2 File Editor")
        .navigationSubtitle(session.isDirty ? "Edited" : "")
        .focusedSceneValue(\.session, session)
        .fileImporter(isPresented: $session.isImporterPresented, allowedContentTypes: Self.openTypes) { result in
            switch result {
            case let .success(url): session.beginOpen(url)
            case let .failure(error): session.reportImportFailure(error)
            }
        }
        .confirmationDialog(
            "Discard unsaved changes?",
            isPresented: Binding(
                get: { session.pendingDiscard != nil },
                set: { if !$0 { session.pendingDiscard = nil } }),
            presenting: session.pendingDiscard
        ) { action in
            Button("Discard Changes", role: .destructive) { session.confirmDiscard(action) }
            Button("Cancel", role: .cancel) { session.pendingDiscard = nil }
        } message: { _ in
            Text("The edits to \(session.openedFile?.name ?? "this file") have not been saved with Save & Encrypt.")
        }
        .onChange(of: settings.datDefsOverride) { session.reloadChronicles() }
        .background(WindowCloseObserver(
            onAttach: { session.window = $0 },
            shouldClose: { CloseConfirmation.shouldClose($0, session: session) },
            onClose: { Task { await session.shutdown() } }))
        .task {
            session.start()
            SessionRegistry.shared.register(session, openWindow: openWindow)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { session.requestOpen() } label: {
                Label("Open & Decrypt", systemImage: "lock.open")
            }
            .help("Open & Decrypt (⌘O)")
            .disabled(session.isBusy)

            Button { Task { await session.saveAndEncrypt() } } label: {
                Label("Save & Encrypt", systemImage: "lock.doc")
            }
            .help("Save & Encrypt (⌘S)")
            .disabled(session.isBusy || session.openedFile == nil)

            Button { session.requestSaveTxt() } label: {
                Label("Save TXT", systemImage: "doc.plaintext")
            }
            .help("Save TXT (⇧⌘S)")
            .disabled(session.isBusy || session.openedFile == nil)

            Button { session.requestReopen() } label: {
                Label("ReOpen", systemImage: "arrow.clockwise")
            }
            .help("Open the file again with the current chronicle and text mode")
            .disabled(session.isBusy || session.openedFile == nil)

            Button { session.openTable() } label: {
                Label("Open Table", systemImage: "tablecells")
            }
            .help("Open the table text file in its default app")
            .disabled(session.isBusy || session.openedFile == nil)
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Picker("Chronicle", selection: settings.$chronicle) {
                ForEach(session.chronicles.entries) { entry in
                    Text(entry.name).tag(entry.dirDDF)
                }
            }
            .help("Chronicle: DDF folder used to open .dat files")
            .frame(minWidth: 170)

            Picker("Version", selection: settings.$protocolVersion) {
                ForEach(session.chronicles.protocols, id: \.rawValue) { version in
                    Text(version.header).tag(version.rawValue)
                }
            }
            .help("Lineage2Ver used by Save & Encrypt")
            .frame(minWidth: 140)

            Picker("Text Mode", selection: settings.$textMode) {
                ForEach(TextMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .help("How 8-bit strings are read and written")
            .frame(minWidth: 150)
        }
    }
}
