import AppKit
import SwiftUI

/// The text editor: a plain-text TextKit 2 `NSTextView` with soft wrap off, built for multi-megabyte
/// tables. The text is loaded in one storage edit when the session's revision changes and read back
/// only on save.
struct EditorTextView: NSViewRepresentable {
    let session: DocumentSession

    func makeCoordinator() -> Coordinator {
        Coordinator(session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        // TextKit 2 view; `.layoutManager` is never touched (it would fall back to TextKit 1).
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = false
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.font = EditorController.font
        textView.defaultParagraphStyle = EditorController.paragraphStyle
        textView.typingAttributes = EditorController.attributes
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isGrammarCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        // Soft wrap off: the container is as wide as the longest line, scrolled horizontally.
        textView.isHorizontallyResizable = true
        textView.isVerticallyResizable = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        if let container = textView.textContainer {
            container.widthTracksTextView = false
            container.containerSize = NSSize(
                width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }

        textView.delegate = context.coordinator
        session.editor.attach(textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        // An empty window (no file) has nothing to save, so it never takes edits.
        let editable = !session.isBusy && session.openedFile != nil
        if textView.isEditable != editable { textView.isEditable = editable }
        if context.coordinator.appliedRevision != session.textRevision {
            context.coordinator.appliedRevision = session.textRevision
            session.editor.load(session.text)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let session: DocumentSession
        var appliedRevision = 0

        init(session: DocumentSession) {
            self.session = session
        }

        /// Called for user edits only (programmatic storage edits do not send it).
        func textDidChange(_ notification: Notification) {
            if !session.isDirty, session.openedFile != nil { session.isDirty = true }
        }
    }
}
