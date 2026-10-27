import AppKit
import L2Crypt

/// The Save TXT dialog: a save panel with the original's encoding choice.
@MainActor
enum SaveTxtPanel {
    private static let choices: [(title: String, encoding: TextCodec.Encoding)] = [
        ("UTF-8", .utf8(bom: false)),
        ("UTF-8 with BOM", .utf8(bom: true)),
        ("Unicode (UTF-16 LE, BOM)", .utf16LE(bom: true)),
        ("Unicode (UTF-16 LE)", .utf16LE(bom: false)),
        ("ANSI (ISO-8859-1)", .latin1),
    ]

    /// Asks for a destination and an encoding; nil when cancelled.
    static func run(suggestedName: String, encoding: TextCodec.Encoding) -> (url: URL, encoding: TextCodec.Encoding)? {
        let panel = NSSavePanel()
        panel.title = "Save TXT"
        panel.nameFieldStringValue = suggestedName
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false

        let popup = NSPopUpButton(frame: .zero, pullsDown: false)
        popup.addItems(withTitles: choices.map(\.title))
        popup.selectItem(at: choices.firstIndex { $0.encoding == encoding } ?? 0)
        let label = NSTextField(labelWithString: "Encoding:")
        let accessory = NSStackView(views: [label, popup])
        accessory.orientation = .horizontal
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        panel.accessoryView = accessory

        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return (url, choices[max(0, popup.indexOfSelectedItem)].encoding)
    }
}
