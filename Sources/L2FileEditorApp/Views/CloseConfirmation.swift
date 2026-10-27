import AppKit

/// The Save / Don't Save / Cancel sheet shown when a window with unsaved edits is closed, or when the app
/// quits with unsaved edits in any window.
@MainActor
enum CloseConfirmation {
    enum Choice {
        case save
        case dontSave
        case cancel
    }

    /// `windowShouldClose` of an editor window: true when it may close now. With unsaved edits it shows the
    /// sheet and returns false; Save runs Save & Encrypt and closes the window when that succeeds (on failure
    /// the window stays open with the error in its status bar and log), Don't Save closes it, Cancel keeps it.
    static func shouldClose(_ window: NSWindow, session: DocumentSession) -> Bool {
        if session.closeConfirmed || !session.hasUnsavedEdits { return true }
        guard window.attachedSheet == nil else { return false }
        Task {
            switch await ask(session, in: window) {
            case .save:
                if await save(session) { window.close() }
            case .dontSave:
                session.closeConfirmed = true
                window.close()
            case .cancel:
                break
            }
        }
        return false
    }

    /// `applicationShouldTerminate`: asks about each window with unsaved edits in turn. True when the app may
    /// quit; false when the user chose Cancel, a save failed, or a window is already showing a sheet.
    static func confirmQuit(_ sessions: [DocumentSession]) async -> Bool {
        for session in sessions where session.hasUnsavedEdits && !session.closeConfirmed {
            if let window = session.window {
                guard window.attachedSheet == nil else {
                    window.makeKeyAndOrderFront(nil)
                    NSSound.beep()
                    return false
                }
                window.makeKeyAndOrderFront(nil)
            }
            switch await ask(session, in: session.window) {
            case .save:
                guard await save(session) else {
                    session.window?.makeKeyAndOrderFront(nil)
                    return false
                }
            case .dontSave:
                session.closeConfirmed = true
            case .cancel:
                return false
            }
        }
        return true
    }

    /// Waits for a running Open/Save, then runs Save & Encrypt only when edits are still unsaved (a ⌘S that
    /// was in flight may have saved them already). True when nothing is left unsaved.
    static func save(_ session: DocumentSession) async -> Bool {
        await session.waitUntilIdle()
        if session.hasUnsavedEdits { await session.saveAndEncrypt() }
        return !session.hasUnsavedEdits
    }

    /// Shows the sheet on `window` (an app-modal alert without one) and returns the choice.
    private static func ask(_ session: DocumentSession, in window: NSWindow?) async -> Choice {
        let name = session.openedFile?.name ?? "this file"
        let alert = NSAlert()
        alert.messageText = "Do you want to save the changes you made to \(name)?"
        alert.informativeText = "Save runs Save & Encrypt (a .bak of the original is kept). "
            + "Your changes are lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        let dontSave = alert.addButton(withTitle: "Don't Save")
        dontSave.hasDestructiveAction = true
        dontSave.keyEquivalent = "d"
        dontSave.keyEquivalentModifierMask = .command
        let response: NSApplication.ModalResponse
        if let window {
            response = await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
            }
        } else {
            response = alert.runModal()
        }
        switch response {
        case .alertFirstButtonReturn: return .save
        case .alertThirdButtonReturn: return .dontSave
        default: return .cancel
        }
    }
}
