import AppKit
import SwiftUI
import Defaults
@testable import TypeNBash

@main
struct MarkdownFindIntegrationChecks {
    // Keep the query guard deterministic if the desktop user activates another
    // app during the fixture. AppKit still owns the real first-responder chain.
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }

    @Observable final class Document {
        var text = "# Search fixture\n\nBarrett met BARRETT and café.\n\n==Keep this highlight== and **bold** with `code`.\n\n| Name | Score |\n| --- | ---: |\n| Barrett | 1 |\n\n- one\n- two\n\n> Quoted with emoji 😀\n\nBarrett again.\n"
        var fancy = true
        var identity = UUID()
        var focused = true
        let session = EditorSession()
    }

    struct Fixture: View {
        @Bindable var document: Document
        var body: some View {
            VStack(spacing: 0) {
                EditorFindBar(session: document.session)
                if document.fancy {
                    RichMarkdownEditor(mdText: $document.text, editorIsFocused: $document.focused, session: document.session)
                        .id(document.identity)
                } else {
                    CodeEditorTextView(text: $document.text, fileURL: URL(filePath: "/tmp/fixture.md"), options: EditorOptions(), session: document.session)
                }
            }
        }
    }

    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run() } catch { fatalError("Markdown find checks: \(error)") }
            exit(0)
        }
        NSApp.run()
    }

    /// The last TextFinder result each editor reported, as the find bar sees them.
    @MainActor final class Results {
        var last: [ObjectIdentifier: FindResult] = [:]
        private var token: NotificationCenter.ObservationToken?
        init() {
            token = NotificationCenter.default.addObserver(for: TextFinder.DidFindMessage.self) { [weak self] message in
                self?.last[message.clientIdentifier] = message.result
            }
        }
        subscript(view: NSTextView) -> FindResult? { last[ObjectIdentifier(view)] }
    }

    @MainActor static func run() async throws {
        let pasteboard = NSPasteboard(name: .find)
        let previous = pasteboard.string(forType: .string)
        let defaults = UserDefaults.standard
        let keys: [DefaultKey<Bool>] = [.findIgnoresCase, .findUsesRegularExpression, .findInSelection,
                                        .findSearchesIncrementally, .findIsWrap]
        let saved = keys.map { defaults[$0] }
        defer {
            pasteboard.clearContents()
            if let previous { pasteboard.setString(previous, forType: .string) }
            for (key, value) in zip(keys, saved) { defaults[key] = value }
        }
        for (key, value) in zip(keys, [true, false, false, true, true]) { defaults[key] = value }
        let results = Results()
        let first = Document()
        let second = Document()
        let original = first.text
        let host = NSHostingView(rootView: HStack {
            Fixture(document: first)
            Fixture(document: second)
        })
        let window = FixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 1300, height: 650),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle()
        guard let finder = first.session.markdownFinder, let document = finder.textView,
              let otherView = second.session.markdownFinder?.textView else {
            fatalError("Both Markdown editors must attach")
        }
        precondition(document !== otherView && first.session.findTextView === document)

        // Rich text: no syntax on screen, and an untouched document is never rewritten.
        for syntax in ["#", "|", "**", "==", "`", "- "] {
            precondition(!document.string.contains(syntax), "Formatted view must not show \(syntax): \(document.string.debugDescription)")
        }
        precondition(first.text == original && document.textLayoutManager == nil, "Load must not rewrite the file; tables need TextKit 1")
        // Edit a table cell: only that block is regenerated, and undo restores the source exactly.
        let text = document.string as NSString
        var scoreCell: NSRange?
        text.enumerateSubstrings(in: NSRange(location: 0, length: text.length), options: .byParagraphs) { _, range, _, stop in
            guard range.location < text.length,
                  let block = (document.textStorage?.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock,
                  block.startingRow == 1, block.startingColumn == 0 else { return }
            scoreCell = range
            stop.pointee = true
        }
        guard let scoreCell else { fatalError("The table must render as text table cells") }
        window.makeFirstResponder(document)
        document.setSelectedRange(NSRange(location: scoreCell.location, length: 0))
        document.insertTab(nil)
        precondition(text.substring(with: document.selectedRange()) == "1", "Tab must select the next cell: \(text.substring(with: document.selectedRange()))")
        document.insertText("1X", replacementRange: document.selectedRange())
        try await settle()
        precondition(first.text == original.replacingOccurrences(of: "| Barrett | 1 |", with: "| Barrett | 1X |"), "Only the table may change: \(first.text)")
        document.undoManager?.undo()
        try await settle()
        precondition(first.text == original, "Undo must restore the source byte for byte: \(first.text)")
        // A quote is a full-width text block: one line, not one character per line.
        let quote = (document.string as NSString).range(of: "Quoted with emoji 😀")
        if let layout = document.layoutManager, let container = document.textContainer {
            layout.ensureLayout(for: container)
            var lines = 0
            layout.enumerateLineFragments(forGlyphRange: layout.glyphRange(forCharacterRange: quote, actualCharacterRange: nil)) { _, _, _, _, _ in lines += 1 }
            precondition(lines == 1, "Quote must lay out at full width: \(lines) lines")
        }
        // Editing a paragraph that ends in an emoji (a surrogate pair) must save.
        document.setSelectedRange(NSRange(location: NSMaxRange(quote), length: 0))
        document.insertText("!", replacementRange: document.selectedRange())
        try await settle()
        precondition(first.text.contains("> Quoted with emoji 😀!"), "Quote edit must save: \(first.text)")
        document.undoManager?.undo()
        try await settle()
        precondition(first.text == original, "Quote undo must restore the source")
        // Markdown typed in Formatted becomes formatting as it is typed, and saves without escapes.
        func type(_ keys: String) {
            for key in keys {
                if key == "\n" { document.insertNewline(nil) } else { document.insertText(String(key), replacementRange: document.selectedRange()) }
            }
        }
        document.setSelectedRange(NSRange(location: (document.string as NSString).length, length: 0))
        type("\n## Typed heading\n> Typed quote\n\n- typed item\n")
        document.insertNewline(nil)
        type("Typed **bold** and `code` and [link](https://x.com) with 5 * 3 and snake_case\n```swift\nlet y = 2")
        try await settle()
        for syntax in ["##", "**", "`", "](", "> "] {
            precondition(!document.string.contains(syntax), "Typed \(syntax) must render: \(document.string.debugDescription)")
        }
        for saved in ["\n## Typed heading\n", "\n> Typed quote\n", "\n- typed item\n",
                      "Typed **bold** and `code` and [link](https://x.com) with 5 * 3 and snake_case", "```swift\nlet y = 2\n```"] {
            precondition(first.text.contains(saved), "Typed Markdown must save as \(saved.debugDescription): \(first.text)")
        }
        first.text = original
        try await settle()
        precondition(!document.string.contains("Typed"), "Reloading the binding must replace the typed text")

        let matches = (document.string.lowercased().components(separatedBy: "barrett").count - 1)

        TextFinderSettings.shared.findString = ""
        document.setSelectedRange(NSRange(location: 0, length: 0))
        window.makeFirstResponder(document)
        let commandF = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                       timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                       characters: "f", charactersIgnoringModifiers: "f", isARepeat: false, keyCode: 3)!
        NSApp.postEvent(commandF, atStart: false)
        try await settle()
        precondition(first.session.isFindBarPresented, "Command-F must open the shared bar")
        guard let input = window.firstResponder as? NSTextView, input !== document else {
            fatalError("Find field must take focus")
        }
        input.insertText("Bar", replacementRange: input.selectedRange())
        try await settle()
        precondition(results[document]?.count == matches, "count=\(String(describing: results[document]?.count)), query=\(TextFinderSettings.shared.findString)")
        input.insertText("rett", replacementRange: input.selectedRange())
        try await settle()
        precondition(TextFinderSettings.shared.findString == "Barrett" && results[document]?.count == matches)
        precondition(first.text == original && window.firstResponder === input)
        precondition(results[otherView] == nil && second.text == original, "Search must stay in its own pane")

        let string = document.string as NSString
        first.session.performFind(.nextMatch)
        try await settle()
        precondition(results[document]?.matchedRange == string.range(of: "BARRETT"),
                     "Next must select the next match: \(String(describing: results[document]?.matchedRange))")
        first.session.performFind(.previousMatch)
        try await settle()
        precondition(results[document]?.matchedRange == string.range(of: "Barrett") && results[document]?.currentMatchIndex == 1)
        precondition(window.firstResponder === input, "Navigation must preserve field focus")

        TextFinderSettings.shared.replacementString = "Replaced"
        first.session.performFind(.replaceAndFind)
        try await settle()
        precondition(first.text.contains("Replaced") && second.text == original, "Replacement must reach the binding: \(first.text)")
        window.makeFirstResponder(document)
        document.undoManager?.undo()
        try await settle()
        precondition(first.text == original, "Replacement must undo: text=\(first.text)")
        document.undoManager?.redo()
        try await settle()
        precondition(first.text.contains("Replaced"), "Redo must publish the replacement")
        document.undoManager?.undo()
        try await settle()
        first.session.performFind(.replaceAll)
        try await settle()
        precondition(first.text.components(separatedBy: "Replaced").count == matches + 1 && second.text == original, "Replace All: \(first.text)")
        window.makeFirstResponder(document)
        document.undoManager?.undo()
        try await settle()
        precondition(first.text == original, "Replace All must undo in one step")
        first.session.dismissFind()
        precondition(window.firstResponder === document)

        // Switch engines with the bar open, then switch documents.
        first.session.find()
        TextFinderSettings.shared.findString = "Barrett"
        try await settle()
        first.fancy = false
        try await settle()
        precondition(first.session.markdownFinder == nil && first.session.textView != nil)
        first.fancy = true
        try await settle()
        precondition(first.session.markdownFinder !== finder && first.session.textView == nil)
        first.text = "# New document\n\nBarrett once.\n"
        first.identity = UUID()
        try await settle()
        guard let switched = first.session.findTextView, switched !== document else { fatalError("New document must attach") }
        first.session.performFind(.replaceAll)
        try await settle()
        precondition(first.text.contains("Replaced once") && second.text == original)
        print("PASS: Formatted rich text without syntax, Markdown typed as formatting, byte-identical load and undo, table cell editing and Tab, full-width quotes, emoji-ending edits, native find, Command-F, incremental focus, navigation/counts, replacement binding/undo, pane isolation, mode and document switching")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(1000)) }
}
