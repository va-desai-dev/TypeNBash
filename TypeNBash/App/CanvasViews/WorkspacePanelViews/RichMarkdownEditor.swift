import AppKit
import MarkdownEngine
import SwiftUI

/// The Formatted Markdown view: a rich-text editor that keeps the file as Markdown.
/// Syntax is never shown here; the Source toggle is where Markdown is edited.
struct RichMarkdownEditor: NSViewRepresentable {
    @Binding var mdText: String
    @Binding var editorIsFocused: Bool
    let session: EditorSession
    var fileURL: URL?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let textView = MarkdownRichTextView(usingTextLayoutManager: false)
        let scrollView = NSScrollView()
        textView.textContainer?.replaceLayoutManager(MarkdownRichLayoutManager())
        textView.document = MarkdownRichText(baseURL: fileURL?.deletingLastPathComponent(), theme: AppTheme.shared.markdownTheme)
        textView.isRichText = true
        textView.allowsUndo = true
        textView.usesFontPanel = true
        textView.drawsBackground = false

        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false


        textView.textContainerInset = NSSize(width: 60, height: 12)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [.foregroundColor: AppTheme.shared.markdownTheme.link, .cursor: NSCursor.pointingHand]

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.scrollsDynamically = true
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        context.coordinator.textView = textView
        context.coordinator.load(mdText)
        textView.delegate = context.coordinator
        textView.textStorage?.delegate = context.coordinator
        let finder = context.coordinator.finder
        DispatchQueue.main.async {
            finder.attach(to: textView, session: session)
            if editorIsFocused { textView.window?.makeFirstResponder(textView) }
        }
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        if mdText != context.coordinator.markdown { context.coordinator.load(mdText) }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.finder.detach()
    }

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {
        var parent: RichMarkdownEditor
        weak var textView: MarkdownRichTextView?
        let finder = MarkdownFindController()
        /// The Markdown last loaded or written, so the binding's echo doesn't reload.
        private(set) var markdown = ""
        private var isLoading = false

        init(_ parent: RichMarkdownEditor) { self.parent = parent }

        func load(_ text: String) {
            guard let textView, let storage = textView.textStorage else { return }
            markdown = text
            isLoading = true
            storage.setAttributedString(textView.document.load(text))
            isLoading = false
            textView.undoManager?.removeAllActions(withTarget: storage)
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.typingAttributes = storage.length > 0
                ? storage.attributes(at: 0, effectiveRange: nil) : textView.document.bodyAttributes
        }

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard !isLoading, let document = textView?.document else { return }
            // Neighbors too: a deletion's range is empty, and a join changes both sides.
            let start = max(0, editedRange.location - 1)
            let probe = NSRange(location: start, length: min(textStorage.length, NSMaxRange(editedRange) + 1) - start)
            textStorage.enumerateAttribute(.markdownChunk, in: probe) { value, _, _ in
                if let chunk = value as? Int { document.dirty.insert(chunk) }
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView, let storage = textView.textStorage else { return }
            markdown = textView.document.markdown(from: storage)
            parent.mdText = markdown
        }
    }
}
