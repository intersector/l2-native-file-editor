import AppKit
import SwiftUI

/// Menu commands of the original (File, Find, Options, About), routed to the focused window's session.
/// The File items go `after:` the system groups so New Window (⌘N) and Close (⌘W) stay in the menu.
struct AppCommands: Commands {
    @FocusedValue(\.session) private var session
    private var settings = AppSettings()

    static let credits = "L2 File Editor — macOS port of L2FileEdit by Miko (l2encdec by DStuff, "
        + "l2asm-disasm by DStuff/czardadius, open-l2encdec by ritsuwastaken)"

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About L2 File Editor") { Self.showAbout() }
        }
        CommandGroup(after: .newItem) {
            Button("Open & Decrypt…") { session?.requestOpen() }
                .keyboardShortcut("o")
                .disabled(session.map { $0.isBusy } ?? true)
            Button("ReOpen") { session?.requestReopen() }
                .disabled(session.map { $0.isBusy || $0.openedFile == nil } ?? true)
            Button("Open Table") { session?.openTable() }
                .disabled(session.map { $0.isBusy || $0.openedFile == nil } ?? true)
        }
        CommandGroup(after: .saveItem) {
            Button("Save & Encrypt") {
                guard let session else { return }
                Task { await session.saveAndEncrypt() }
            }
            .keyboardShortcut("s")
            .disabled(session.map { $0.isBusy || $0.openedFile == nil } ?? true)
            Button("Save TXT…") { session?.requestSaveTxt() }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(session.map { $0.isBusy || $0.openedFile == nil } ?? true)
        }
        CommandGroup(replacing: .textEditing) {
            Menu("Find") {
                findButton("Find…", .showFindInterface)
                    .keyboardShortcut("f")
                findButton("Find and Replace…", .showReplaceInterface)
                    .keyboardShortcut("f", modifiers: [.command, .option])
                findButton("Find Next", .nextMatch)
                    .keyboardShortcut("g")
                findButton("Find Previous", .previousMatch)
                    .keyboardShortcut("g", modifiers: [.command, .shift])
                findButton("Use Selection for Find", .setSearchString)
                    .keyboardShortcut("e")
            }
        }
        CommandGroup(replacing: .toolbar) {
            Toggle("Show Toolbar", isOn: settings.$showToolbar)
            Toggle("Show Program Log", isOn: settings.$showLog)
        }
    }

    private func findButton(_ title: String, _ action: NSTextFinder.Action) -> some View {
        Button(title) { session?.editor.performFind(action) }
            .disabled(session == nil)
    }

    private static func showAbout() {
        let credits = NSAttributedString(
            string: credits,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.labelColor,
            ])
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1.0"
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "L2 File Editor",
            .applicationVersion: version,
            .credits: credits,
        ])
    }
}
