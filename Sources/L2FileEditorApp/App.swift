import SwiftUI

/// L2 File Editor: a macOS port of L2FileEdit by Miko. Started from `EntryPoint`.
struct L2FileEditorApp: App {
    static let windowID = "editor"

    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("L2 File Editor", id: Self.windowID) {
            MainView()
        }
        .defaultSize(width: 1180, height: 760)
        .handlesExternalEvents(matching: [])
        .commands { AppCommands() }

        Settings {
            SettingsView()
        }
    }
}
