import SwiftUI

/// The live editor windows' sessions, and files opened from Finder waiting for a window.
///
/// Files that arrive before any window exists (an "Open With" that launches the app) are queued and taken
/// by the first window when it starts; later ones go to an empty idle window, or open a new window.
@MainActor
final class SessionRegistry {
    static let shared = SessionRegistry()

    private var sessions: [DocumentSession] = []
    /// The live sessions, in the order their windows opened.
    var all: [DocumentSession] { sessions }
    private var pendingURLs: [URL] = []
    private var openWindow: OpenWindowAction?
    private var windowRequested = false

    func register(_ session: DocumentSession, openWindow: OpenWindowAction) {
        if !sessions.contains(where: { $0 === session }) { sessions.append(session) }
        self.openWindow = openWindow
        windowRequested = false
        dispatch()
    }

    func unregister(_ session: DocumentSession) {
        sessions.removeAll { $0 === session }
    }

    /// Files opened from Finder (or `open -a`).
    func open(_ urls: [URL]) {
        pendingURLs += urls
        dispatch()
    }

    /// Shuts every session down (cancel and await its operation, then remove its temp files).
    func shutdownAll() async {
        for session in sessions {
            await session.shutdown()
        }
    }

    private func dispatch() {
        while let url = pendingURLs.first {
            if let session = sessions.first(where: \.canTakeFile) {
                pendingURLs.removeFirst()
                session.requestOpen(url)
            } else {
                if !windowRequested, let openWindow {
                    windowRequested = true
                    openWindow(id: L2FileEditorApp.windowID)
                }
                return
            }
        }
    }
}
