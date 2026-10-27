import AppKit

/// The session's handle on the editor's `NSTextView`: loads text, reads it on save, moves the
/// caret to an error and drives the find bar.
@MainActor
final class EditorController {
    private weak var textView: NSTextView?

    static let font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)

    /// No fixed tab stops, one every 8 characters: the default style's 12 stops would break any
    /// line with more cells onto the next line.
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.tabStops = []
        style.defaultTabInterval = 8 * font.advancement(forGlyph: font.glyph(withName: "space")).width
        style.lineBreakMode = .byClipping
        return style
    }()

    static let attributes: [NSAttributedString.Key: Any] = [
        .font: font, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle,
    ]

    func attach(_ textView: NSTextView) {
        self.textView = textView
    }

    /// Replaces the whole text in one storage edit (no per-line work) and resets undo and the caret.
    func load(_ text: String) {
        guard let textView, let storage = textView.textStorage else { return }
        let attributed = NSAttributedString(string: text, attributes: Self.attributes)
        storage.replaceCharacters(in: NSRange(location: 0, length: storage.length), with: attributed)
        textView.undoManager?.removeAllActions()
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
    }

    /// The live editor text as native UTF-8, or nil when no editor is attached.
    func currentText() -> String? {
        guard let textView else { return nil }
        var text = textView.string
        text.makeContiguousUTF8()
        return text
    }

    /// Selects the cell at 1-based `line` and `column` (Unicode scalars) and scrolls to it.
    func select(line: Int, column: Int) {
        guard let textView, let storage = textView.textStorage else { return }
        let string = storage.mutableString
        var lineStart = 0
        var current = 1
        while current < line {
            let newline = string.range(
                of: "\n", options: .literal, range: NSRange(location: lineStart, length: string.length - lineStart))
            guard newline.location != NSNotFound else { break }
            lineStart = newline.location + 1
            current += 1
        }
        var contentsEnd = 0
        string.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: NSRange(location: lineStart, length: 0))
        let lineText = string.substring(with: NSRange(location: lineStart, length: contentsEnd - lineStart))

        var offset = 0
        for (index, scalar) in lineText.unicodeScalars.enumerated() where index < column - 1 {
            offset += scalar.utf16.count
        }
        let cellStart = lineStart + offset
        let tab = string.range(
            of: "\t", options: .literal, range: NSRange(location: cellStart, length: contentsEnd - cellStart))
        let cellEnd = tab.location == NSNotFound ? contentsEnd : tab.location
        let range = NSRange(location: cellStart, length: cellEnd - cellStart)

        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
        textView.showFindIndicator(for: range)
    }

    /// Shows the find bar (or performs another find-bar action) in the editor.
    func performFind(_ action: NSTextFinder.Action) {
        guard let textView else { return }
        let sender = NSMenuItem()
        sender.tag = action.rawValue
        textView.window?.makeFirstResponder(textView)
        textView.performTextFinderAction(sender)
    }
}
