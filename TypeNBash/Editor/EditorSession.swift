import AppKit
import SwiftUI
import SyntaxFormat
import TextEditing

/// The UI bridge belongs to one editor, so toolbar actions never reach a terminal
/// or another window through the application-wide responder chain.
@Observable final class EditorSession {
    @ObservationIgnored weak var textView: EditorTextView?
    @ObservationIgnored weak var csvGrid: CSVGridBodyView?
    var hasPendingCSVEdit = false
    var syntaxController: SyntaxController?
    var position = "Ln 1, Col 1"

    /// Whether this editor's inline Find & Replace bar is showing.
    var isFindBarPresented = false

    /// Bumped every time the find field should take focus, so pressing ⌘F again
    /// while the bar is already open still moves the caret back into it.
    private(set) var findFocusRequest = 0

    func csvAnalysisSnapshot(scope: CSVAnalysisSnapshot.Scope = .allRows) throws -> CSVAnalysisSnapshot {
        guard let csvGrid else { throw CSVAnalysisError.noTable }
        return try csvGrid.analysisSnapshot(scope: scope)
    }

    /// The text to hand the console: the selection, or the `# %%` cell the caret
    /// sits in when nothing is selected.
    ///
    /// This is the RStudio and Positron gesture. The console is the result
    /// surface — output lands there and stays there — so all this has to do is
    /// decide which lines to send.
    func consoleSnippet() -> String? {
        guard let textView else { return nil }
        let selection = textView.selectedString
        if !selection.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return selection }

        let text = textView.string as NSString
        guard text.length > 0 else { return nil }
        var lines: [NSRange] = []
        var position = 0
        while position < text.length {
            let line = text.lineRange(for: NSRange(location: position, length: 0))
            lines.append(line)
            position = NSMaxRange(line)
        }
        guard !lines.isEmpty else { return nil }

        func isMarker(_ index: Int) -> Bool {
            text.substring(with: lines[index])
                .trimmingCharacters(in: .whitespaces)
                .hasPrefix(NotebookScript.cellMarker)
        }

        let caret = min(textView.selectedRange().location, text.length)
        var current = lines.lastIndex { $0.location <= caret } ?? 0
        // A caret resting on the delimiter means the cell it introduces.
        if isMarker(current) { current = min(current + 1, lines.count - 1) }

        var start = current
        while start > 0, !isMarker(start) { start -= 1 }
        if isMarker(start) { start += 1 }
        var end = current
        while end + 1 < lines.count, !isMarker(end + 1) { end += 1 }
        guard start <= end, end < lines.count else { return nil }

        let snippet = text.substring(with: NSRange(location: lines[start].location,
                                                   length: NSMaxRange(lines[end]) - lines[start].location))
        return snippet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : snippet
    }

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
