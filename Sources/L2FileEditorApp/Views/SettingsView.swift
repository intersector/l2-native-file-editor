import AppKit
import L2Crypt
import SwiftUI

/// Preferences window (the original's Options menu and INI `[Dir]` keys).
struct SettingsView: View {
    private var settings = AppSettings()
    @State private var chronicles = Chronicles.load(datDefsOverride: nil)

    var body: some View {
        Form {
            Section("Defaults") {
                Picker("Chronicle", selection: settings.$chronicle) {
                    ForEach(chronicles.entries) { Text($0.name).tag($0.dirDDF) }
                }
                Picker("Lineage2Ver (Save & Encrypt)", selection: settings.$protocolVersion) {
                    ForEach(chronicles.protocols, id: \.rawValue) { Text($0.header).tag($0.rawValue) }
                }
                Picker("Text mode", selection: settings.$textMode) {
                    ForEach(TextMode.allCases) { Text($0.title).tag($0) }
                }
                Picker("Float format", selection: settings.$floatFormat) {
                    ForEach(FloatFormat.allCases) { Text($0.title).tag($0) }
                }
            }
            Section("Folders") {
                pathRow("Temp folder", text: settings.$tempDir, directory: true, placeholder: AppSettings.defaultTempDir)
                Toggle("Delete temp files when the window closes", isOn: settings.$deleteTempOnClose)
                pathRow("DAT_defs folder", text: settings.$datDefsOverride, directory: true, placeholder: "Bundled DAT_defs")
                pathRow("l2encdec helper", text: settings.$helperOverride, directory: false, placeholder: "Bundled helper")
            }
            Section("Window") {
                Toggle("Show toolbar", isOn: settings.$showToolbar)
                Toggle("Show Program Log", isOn: settings.$showLog)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .fixedSize(horizontal: false, vertical: true)
        .onChange(of: settings.datDefsOverride) {
            chronicles = Chronicles.load(datDefsOverride: settings.datDefsOverrideURL)
        }
        .task { chronicles = Chronicles.load(datDefsOverride: settings.datDefsOverrideURL) }
    }

    private func pathRow(_ title: String, text: Binding<String>, directory: Bool, placeholder: String) -> some View {
        LabeledContent(title) {
            HStack {
                TextField(title, text: text, prompt: Text(placeholder))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.canCreateDirectories = directory
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url { text.wrappedValue = url.path }
                }
                Button("Reset") { text.wrappedValue = "" }
                    .disabled(text.wrappedValue.isEmpty)
            }
        }
    }
}
