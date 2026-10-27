import AppKit

/// Receives files opened from Finder, including the one that launches the app. Before the app quits it asks
/// about unsaved edits (Save / Don't Save / Cancel per window), then shuts the windows' sessions down
/// (cancel running helpers, remove temp files).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
        SessionRegistry.shared.open(urls.filter(\.isFileURL))
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            guard await CloseConfirmation.confirmQuit(SessionRegistry.shared.all) else {
                NSApplication.shared.reply(toApplicationShouldTerminate: false)
                return
            }
            await SessionRegistry.shared.shutdownAll()
            NSApplication.shared.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
