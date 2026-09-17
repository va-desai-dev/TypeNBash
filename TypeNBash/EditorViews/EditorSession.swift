import AppKit
import SwiftUI
import SyntaxFormat
import TextEditing

/// The UI bridge belongs to one editor, so toolbar actions never reach a terminal
/// or another window through the application-wide responder chain.
@Observable final class EditorSession {
    @ObservationIgnored weak var textView: EditorTextView?
    var syntaxController: SyntaxController?
    var position = "Ln 1, Col 1"

    /// Whether this editor's inline Find & Replace bar is showing.
    var isFindBarPresented = false

    /// Bumped every time the find field should take focus, so pressing ⌘F again
    /// while the bar is already open still moves the caret back into it.
    private(set) var findFocusRequest = 0

    func perform(_ action: Selector) {
        guard let textView, let window = textView.window else { return }
        window.makeFirstResponder(textView)
        NSApp.sendAction(action, to: textView, from: nil)
    }

    /// Reveals the find bar and puts focus in its search field.
    func find() {
        guard let textView else { return }

        // Seed the field from the selection, the way ⌘F does elsewhere on the
        // platform — but only on the way in, so re-invoking it does not discard
        // a search the user has already typed. Regex is switched off with it
        // because literal selections routinely contain metacharacters.
        if !self.isFindBarPresented {
            let selection = textView.selectedString
            if !selection.isEmpty, !selection.contains(where: \.isNewline) {
                TextFinderSettings.shared.findString = selection
                TextFinderSettings.shared.usesRegularExpression = false
            }
        }

        self.isFindBarPresented = true
        self.findFocusRequest += 1
    }

    /// Hides the find bar, drops the match highlighting, and hands focus back
    /// to the text view.
    func dismissFind() {
        self.isFindBarPresented = false
        guard let textView else { return }
        textView.unhighlight(nil)
        textView.window?.makeFirstResponder(textView)
    }

    /// Runs a find action against this editor and no other.
    ///
    /// The find panel dispatched through `NSApp.sendAction(_:to:from:)` with a
    /// `nil` target, which walks the application-wide responder chain and can
    /// land on whichever text view happens to be first responder. Addressing
    /// the session's own text view keeps a window's search inside that window.
    func performFind(_ action: TextFinder.Action) {
        guard let textView else { return }
        let item = NSMenuItem()
        item.tag = action.rawValue
        textView.performEditorTextFinderAction(item)
    }

    /// Runs the debounced search-as-you-type pass for this editor.
    func incrementalSearch() {
        self.textView?.incrementalSearch(nil)
    }

    func select(_ range: NSRange) {
        guard let textView, NSMaxRange(range) <= (textView.string as NSString).length else { return }
        textView.window?.makeFirstResponder(textView)
        textView.setSelectedRange(range)
        textView.scrollRangeToVisible(range)
    }
}

struct EditorOptions: Equatable {
    var showsInvisibles = true
    var showsIndentGuides = true
    var showsLineNumbers = true
    var wrapsLines = true
    var automaticCompletion = true
    var usesSpaces = true
    var tabWidth = 4

    func apply(to view: EditorTextView) {
        if view.showsInvisibles != showsInvisibles { view.showsInvisibles = showsInvisibles }
        if view.showsIndentGuides != showsIndentGuides { view.showsIndentGuides = showsIndentGuides }
        view.enclosingScrollView?.rulersVisible = showsLineNumbers
        view.wrapsLines = wrapsLines
        view.isAutomaticCompletionEnabled = automaticCompletion
        view.isAutomaticTabExpansionEnabled = usesSpaces
        if view.tabWidth != tabWidth { view.tabWidth = tabWidth }
    }
}

extension EditorTextView {
    func applySyntax(_ syntax: Syntax) {
        commentDelimiters = syntax.commentDelimiters
        indentTokens = syntax.indentation.blockDelimiters.compactMap {
            IndentToken(begin: $0.begin, end: $0.end, ignoreCase: $0.ignoreCase)
        }
        quoteDelimiters = syntax.stringDelimiters + syntax.characterDelimiters
        syntaxCompletionWords = syntax.completionWords
    }
}
