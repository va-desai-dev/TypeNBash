import AppKit
import SwiftUI
import Invisible
import LineEnding
import SyntaxFormat
import SyntaxParsers
@testable import TypeNBash

/// Exercises the actual SwiftUI/AppKit bridge against the bundled grammars.
@main
struct EditorIntegrationChecks {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async {
        let findPasteboard = NSPasteboard(name: .find)
        let previousSearch = findPasteboard.string(forType: .string)
        defer {
            findPasteboard.clearContents()
            if let previousSearch { findPasteboard.setString(previousSearch, forType: .string) }
        }
        var contents = "func example() {\r\n    let exampleValue = 1\r\n}\r\n"
        let binding = Binding(get: { contents }, set: { contents = $0 })
        let session = EditorSession()
        let bridge = CodeEditorTextView(text: binding, fileURL: URL(filePath: "/tmp/example.swift"),
                                        options: EditorOptions(), session: session)
        let host = NSHostingView(rootView: bridge)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.title = "CENTCOM Editor Integration Checks"
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        await settle()
        guard let view = session.textView else { fatalError("Editor did not mount") }
        window.makeFirstResponder(view)
        check(view.lineEnding == .crlf, "Preserves CRLF for inserted newlines")
        check(view.showsInvisibles && view.shownInvisibles == Set(Invisible.allCases), "Invisible glyph categories reach the layout manager")
        check(view.showsIndentGuides && view.enclosingScrollView?.rulersVisible == true, "Indent guides and line numbers enabled")
        check(!view.syntaxCompletionWords.isEmpty && !view.commentDelimiters.isEmpty && !view.indentTokens.isEmpty && !view.quoteDelimiters.isEmpty, "Swift grammar configures completion, comments, indentation, and quotes")
        check(view.isAutomaticCompletionEnabled, "Automatic completion enabled")
        check(session.syntaxController?.outlineItems?.contains(where: { $0.title.contains("example") }) == true, "Parser supplies the symbol navigator")

        // Exercise native completion with a language keyword and a document identifier.
        replace(view, with: "ret")
        var index = 0
        let keywords = view.completions(forPartialWordRange: NSRange(location: 0, length: 3), indexOfSelectedItem: &index) ?? []
        check(keywords.contains("return"), "Swift keyword completion returns return")
        view.insertCompletion("return", forPartialWordRange: NSRange(location: 0, length: 3), movement: NSReturnTextMovement, isFinal: true)
        check(view.string == "return" && contents == "return", "Accepting completion replaces the prefix and updates the binding")
        replace(view, with: "exampleValue\nexam")
        let words = view.completions(forPartialWordRange: NSRange(location: 13, length: 4), indexOfSelectedItem: &index) ?? []
        check(words.contains("exampleValue"), "Document identifier completion works")
        replace(view, with: "_exam")
        check(view.rangeForUserCompletion == NSRange(location: 0, length: 5), "Completion includes underscore at document start")

        replace(view, with: "let value = 1")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        send(view, key: "/", code: 44, modifiers: .command)
        check(view.string == "// let value = 1", "Command-/ comments the current line")
        send(view, key: "/", code: 44, modifiers: .command)
        check(view.string == "let value = 1", "Command-/ uncomments the line")
        send(view, key: "]", code: 30, modifiers: .command)
        check(view.string == "    let value = 1", "Command-] indents")
        send(view, key: "[", code: 33, modifiers: .command)
        check(view.string == "let value = 1", "Command-[ outdents")
        check(contents == view.string, "Editing commands update the SwiftUI binding")

        replace(view, with: "")
        view.insertText("\"", replacementRange: view.selectedRange())
        check(view.string == "\"\"" && view.selectedRange().location == 1, "Language quotes auto-pair")
        replace(view, with: "if true {")
        view.insertNewline(nil)
        check(view.string == "if true {\r\n    ", "Return applies language indentation and CRLF")

        replace(view, with: "first\r\nsecond")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        send(view, key: "\u{F701}", code: 125, modifiers: [.command, .option])
        check(view.string == "second\r\nfirst", "Move-line shortcut preserves contents and line endings")
        // Undo groups close at event boundaries, as they do between real keystrokes.
        await settle()
        session.perform(#selector(EditorTextView.duplicateLine(_:)))
        check(view.string.components(separatedBy: "first").count == 3, "Toolbar action duplicates the selected line")
        await settle()
        view.undoManager?.undo()
        check(view.string == "second\r\nfirst", "Line operation is undoable")

        var options = EditorOptions()
        options.showsInvisibles = false
        options.showsIndentGuides = false
        options.showsLineNumbers = false
        options.wrapsLines = false
        options.automaticCompletion = false
        options.usesSpaces = false
        options.tabWidth = 2
        host.rootView = CodeEditorTextView(text: binding, fileURL: URL(filePath: "/tmp/example.swift"), options: options, session: session)
        await settle()
        check(!view.showsInvisibles && !view.showsIndentGuides && view.enclosingScrollView?.rulersVisible == false, "Display settings propagate to the mounted editor")
        check(!view.wrapsLines && view.enclosingScrollView?.hasHorizontalScroller == true, "Disabling wrapping enables horizontal scrolling")
        check(!view.isAutomaticCompletionEnabled && !view.isAutomaticTabExpansionEnabled && view.tabWidth == 2, "Editing settings propagate")

        host.rootView = CodeEditorTextView(text: binding, fileURL: URL(filePath: "/tmp/example.py"), options: options, session: session)
        await settle()
        replace(view, with: "value = 1")
        view.toggleComment(nil)
        check(view.string == "# value = 1", "Switching grammar changes comment delimiters to Python")
        host.rootView = CodeEditorTextView(text: binding, fileURL: URL(filePath: "/tmp/example.unknown"), options: options, session: session)
        await settle()
        check(view.syntaxCompletionWords.isEmpty && view.commentDelimiters.isEmpty && view.indentTokens.isEmpty && view.quoteDelimiters.isEmpty, "Plain text clears prior language behavior")
        check(session.syntaxController == nil && view.layoutManager?.syntaxHighlights().isEmpty == true, "Plain text clears the controller and old highlighting")

        // The original integration held the initial Binding forever. Replace it and edit.
        var replacementContents = "new document"
        let replacementBinding = Binding(get: { replacementContents }, set: { replacementContents = $0 })
        host.rootView = CodeEditorTextView(text: replacementBinding, fileURL: nil, options: options, session: session)
        await settle()
        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        view.insertText("!", replacementRange: view.selectedRange())
        check(replacementContents == "new document!", "Coordinator uses the current binding after a view update")

        // The inline find bar opens against this editor and native find/replace
        // reaches its text.
        replace(view, with: "alpha beta alpha")
        view.setSelectedRange(NSRange(location: 0, length: 0))
        TextFinderSettings.shared.findString = "beta"
        TextFinderSettings.shared.replacementString = "gamma"
        session.find()
        await settle()
        check(session.isFindBarPresented, "Find and Replace bar opens")
        session.performFind(.nextMatch)
        await settle()
        check((view.string as NSString).substring(with: view.selectedRange()) == "beta", "Find selects the requested match")
        session.performFind(.replace)
        await settle()
        check(view.string == "alpha gamma alpha", "Replace updates the matching text")
        session.dismissFind()
        // ⌘F is covered by `EditorFindBar`, which observes the text view's
        // request for the find interface. It is not mounted here — this harness
        // hosts the bare text view, without the header that carries the bar.

        // Render the production editor bridge using a self-contained source fixture.
        let preview = CodeEditorTextView(text: .constant("struct Example {\n    let title = \"CENTCOM\"\n\n    func greet() {\n        print(title)\n    }\n}\n"), fileURL: URL(filePath: "/tmp/Example.swift"), options: EditorOptions(), session: EditorSession())
            .preferredColorScheme(.dark)
        let previewHost = NSHostingView(rootView: preview)
        window.contentView = previewHost
        await settle()
        func findEditor(_ parent: NSView) -> EditorTextView? {
            if let editor = parent as? EditorTextView { return editor }
            return parent.subviews.compactMap { findEditor($0) }.first
        }
        let previewEditor = findEditor(previewHost)!
        let ruler = previewEditor.enclosingScrollView!.verticalRulerView!
        if let bitmap = ruler.bitmapImageRepForCachingDisplay(in: ruler.bounds) {
            ruler.cacheDisplay(in: ruler.bounds, to: bitmap)
            let hasVisibleNumbers = (0..<bitmap.pixelsHigh).contains { y in
                (0..<bitmap.pixelsWide).contains { x in
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { return false }
                    return color.alphaComponent > 0.5 && color.redComponent > 0.4
                }
            }
            check(hasVisibleNumbers, "Line-number ruler draws visible glyphs in dark mode")
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: "/tmp/centcom-editor-ruler.png"))
        }
        if let bitmap = previewHost.bitmapImageRepForCachingDisplay(in: previewHost.bounds) {
            previewHost.cacheDisplay(in: previewHost.bounds, to: bitmap)
            try! bitmap.representation(using: .png, properties: [:])!.write(to: URL(filePath: "/tmp/centcom-editor-preview.png"))
        }
        print("All editor integration checks passed.")
        window.orderOut(nil)
    }

    @MainActor static func replace(_ view: EditorTextView, with text: String) {
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        view.insertText(text, replacementRange: view.selectedRange())
        view.breakUndoCoalescing()
    }

    @MainActor static func send(_ view: EditorTextView, key: String, code: UInt16, modifiers: NSEvent.ModifierFlags) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                    timestamp: 0, windowNumber: view.window!.windowNumber, context: nil,
                                    characters: key, charactersIgnoringModifiers: key, isARepeat: false, keyCode: code)!
        check(view.performKeyEquivalent(with: event), "Shortcut handled by the focused editor")
    }

    @MainActor static func settle() async { try? await Task.sleep(for: .milliseconds(800)) }
    static func check(_ result: @autoclosure () -> Bool, _ message: String) {
        guard result() else { fatalError("FAIL: \(message)") }
        print("PASS: \(message)")
    }
}
