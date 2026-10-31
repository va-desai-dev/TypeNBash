import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct MarkdownFormattingIntegrationChecks {
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    @Observable final class Document {
        var text = "plain, **bold**, *italic*."
        var focused = false
        let session = EditorSession()
    }
    struct Fixture: View {
        @Bindable var document: Document
        var body: some View {
            RichMarkdownEditor(mdText: $document.text, editorIsFocused: $document.focused, session: document.session)
        }
    }
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            await run()
            exit(0)
        }
        NSApp.run()
    }
    @MainActor static func run() async {
        let first = Document(), second = Document()
        let original = first.text
        let host = NSView(frame: NSRect(x: 0, y: 0, width: 1000, height: 400))
        let toolbar = NSHostingView(rootView: RTFTools(session: first.session).fixedSize().frame(maxWidth: .infinity, alignment: .leading))
        toolbar.frame = NSRect(x: 0, y: 374, width: 180, height: 26)
        host.addSubview(toolbar)
        for (index, document) in [first, second].enumerated() {
            let editor = NSHostingView(rootView: Fixture(document: document))
            editor.frame = NSRect(x: index * 500, y: 0, width: 500, height: 374)
            host.addSubview(editor)
        }
        let window = FixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 1000, height: 400),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        await settle()
        guard let view = first.session.findTextView as? MarkdownRichTextView,
              let other = second.session.findTextView else { fatalError("Editors did not mount") }
        window.makeFirstResponder(view)
        func select(_ word: String) { view.setSelectedRange((view.string as NSString).range(of: word)) }
        func press(_ label: String) {
            let point = toolbar.convert(NSPoint(x: label == "Bold" ? 18 : 45, y: 13), to: nil)
            func event(_ type: NSEvent.EventType) -> NSEvent {
                NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                   timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                   context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
            }
            NSApp.postEvent(event(.leftMouseUp), atStart: false)
            window.sendEvent(event(.leftMouseDown))
        }

        select("bold")
        await settle()
        precondition(first.session.selectedFontTraits.contains(.boldFontMask))
        precondition(!first.session.selectedFontTraits.contains(.italicFontMask))
        select("italic")
        await settle()
        precondition(first.session.selectedFontTraits.contains(.italicFontMask))
        precondition(!first.session.selectedFontTraits.contains(.boldFontMask))
        precondition(first.text == original && view.undoManager?.canUndo != true,
                     "Selection feedback must never format text or create undo actions")
        view.setSelectedRange(NSRange(location: 0, length: NSMaxRange((view.string as NSString).range(of: "bold"))))
        await settle()
        precondition(!first.session.selectedFontTraits.contains(.boldFontMask), "Mixed selection must show bold off")
        print("PASS: toolbar state follows bold, italic and mixed selections without editing")

        select("plain")
        await settle()
        window.makeFirstResponder(other)
        press("Bold")
        await settle()
        precondition(first.text.contains("**plain**") && second.text == original,
                     "Actual header toggle must format only its own editor: \(first.text)")
        precondition(window.firstResponder === view && first.session.selectedFontTraits.contains(.boldFontMask))
        view.undoManager?.undo()
        await settle()
        precondition(first.text == original && !first.session.selectedFontTraits.contains(.boldFontMask))
        view.undoManager?.redo()
        await settle()
        precondition(first.text.contains("**plain**") && first.session.selectedFontTraits.contains(.boldFontMask))
        print("PASS: native header Press preserves selection, targets its pane, updates Markdown and supports undo/redo")

        press("Italics")
        await settle()
        precondition(first.text.contains("***plain***") && first.session.selectedFontTraits.contains([.boldFontMask, .italicFontMask]))
        press("Bold")
        await settle()
        precondition(first.text.contains("*plain*") && !first.session.selectedFontTraits.contains(.boldFontMask)
                     && first.session.selectedFontTraits.contains(.italicFontMask))
        print("PASS: bold and italic toggle independently while preserving the other trait")

        view.setSelectedRange(NSRange(location: (view.string as NSString).length, length: 0))
        await settle()
        let beforeTyping = first.text
        press("Bold")
        await settle()
        precondition(first.text == beforeTyping && first.session.selectedFontTraits.contains(.boldFontMask),
                     "Caret formatting changes typing attributes without changing the document")
        view.insertText("X", replacementRange: view.selectedRange())
        await settle()
        precondition(first.text.contains("**X**"), "New text must use the toolbar's typing format: \(first.text)")
        let italicShortcut = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                              timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                              characters: "i", charactersIgnoringModifiers: "i", isARepeat: false, keyCode: 34)!
        precondition(view.performKeyEquivalent(with: italicShortcut))
        await settle()
        precondition(first.session.selectedFontTraits.contains([.boldFontMask, .italicFontMask]),
                     "Keyboard shortcuts must update header state at the caret")
        print("PASS: caret formatting affects subsequent typing, and keyboard shortcuts update the header")

        let headingSource = "Title with **bold**, *italic*, [link](https://example.com), and `code`.\n\nUntouched __source__.\n"
        first.text = headingSource
        await settle()
        select("Title")
        let headingSelection = view.selectedRange()
        window.makeFirstResponder(other)
        first.session.setHeadingLevel(1)
        await settle()
        precondition(first.text == "# " + headingSource, "Heading 1 must write its Markdown token: \(first.text)")
        precondition(view.selectedRange() == headingSelection && window.firstResponder === view)
        precondition(!view.string.contains("#") && first.session.selectedHeadingLevel == 1)
        precondition(second.text == original, "Heading commands must stay in their editor pane")
        view.undoManager?.undo()
        await settle()
        precondition(first.text == headingSource && first.session.selectedHeadingLevel == 0)
        view.undoManager?.redo()
        await settle()
        precondition(first.text == "# " + headingSource && first.session.selectedHeadingLevel == 1,
                     "Heading redo: \(first.text.debugDescription), level \(String(describing: first.session.selectedHeadingLevel)), selection \(view.selectedRange())")
        for level in 2...6 {
            first.session.setHeadingLevel(level)
            await settle()
            precondition(first.text == String(repeating: "#", count: level) + " " + headingSource,
                         "Heading \(level) must preserve inline formatting and untouched source: \(first.text)")
            precondition(first.session.selectedHeadingLevel == level)
        }
        first.session.setHeadingLevel(0)
        await settle()
        precondition(first.text == headingSource, "Body must remove the heading token without leaving inherited bold")
        print("PASS: Heading 1–6 and Body preserve inline content, cached source, selection, pane isolation and undo/redo")

        first.text = "First paragraph.\n\nSecond paragraph.\n\nThird paragraph."
        await settle()
        let end = NSMaxRange((view.string as NSString).range(of: "Second paragraph."))
        view.setSelectedRange(NSRange(location: 2, length: end - 2))
        first.session.setHeadingLevel(2)
        await settle()
        precondition(first.text == "## First paragraph.\n\n## Second paragraph.\n\nThird paragraph.",
                     "Partial selection must format complete paragraphs: \(first.text)")
        view.undoManager?.undo()
        await settle()
        precondition(first.text == "First paragraph.\n\nSecond paragraph.\n\nThird paragraph.", "Multi-paragraph formatting must undo together")
        first.text = "# Loaded heading\n\nBody"
        await settle()
        precondition(first.session.selectedHeadingLevel == 1, "Loaded heading state: \(String(describing: first.session.selectedHeadingLevel))")
        first.session.setHeadingLevel(0)
        await settle()
        precondition(first.text == "Loaded heading\n\nBody", "A parsed heading's implicit bold must not become emphasis")
        print("PASS: multiple paragraphs format in one undo step, and source-loaded headings map back to Body")

        first.text = ""
        await settle()
        first.session.setHeadingLevel(3)
        precondition(first.text.isEmpty && first.session.selectedHeadingLevel == 3)
        view.insertText("New heading", replacementRange: view.selectedRange())
        view.insertNewline(nil)
        view.insertText("Body text", replacementRange: view.selectedRange())
        await settle()
        precondition(first.text.contains("### New heading\n\nBody text") && first.session.selectedHeadingLevel == 0,
                     "Empty-caret heading must apply to typing, with Return restoring Body: \(first.text)")
        first.text = ""
        await settle()
        for character in "## Typed heading" { view.insertText(String(character), replacementRange: view.selectedRange()) }
        await settle()
        precondition(first.session.selectedHeadingLevel == 2 && first.text.contains("## Typed heading"))
        print("PASS: empty paragraphs, Return, and typed Markdown stay synchronized with heading controls")

        first.text = "> Quoted *text*."
        await settle()
        first.session.setHeadingLevel(2)
        await settle()
        precondition(first.text == "> ## Quoted *text*.", "Heading formatting must preserve quote structure")
        for source in ["- List item", "```\nliteral\n```", "| A | B |\n| --- | --- |\n| 1 | 2 |"] {
            first.text = source
            await settle()
            precondition(!first.session.canSetHeadingLevel)
            first.session.setHeadingLevel(1)
            precondition(first.text == source, "Unsupported block structures must remain intact")
        }
        print("PASS: quotes retain structure; tables, lists and code blocks reject unsupported heading changes")

        // Source markers pick the list style and survive loading untouched.
        let mixedLists = "- dash one\n- dash two\n\n* bullet\n\n1. first"
        first.text = mixedLists
        await settle()
        let paragraphs = view.string.components(separatedBy: "\n")
        precondition(paragraphs[0].hasPrefix("\t–\t") && paragraphs[2].hasPrefix("\t•\t") && paragraphs[3].hasPrefix("\t1.\t"),
                     "List markers: \(paragraphs.map(\.debugDescription))")
        precondition(first.text == mixedLists, "Loading must not rewrite list markers")
        select("dash one")
        await settle()
        precondition(first.session.selectedListKind == .dashed)
        select("bullet")
        await settle()
        precondition(first.session.selectedListKind == .bulleted)
        print("PASS: `-` loads as a dashed list, `*` as bulleted, without rewriting the file")

        func expect(_ kind: MarkdownListKind?, _ markdown: String, _ step: String) async {
            if let kind { first.session.setListKind(kind) } else { first.session.setBodyStyle() }
            await settle()
            precondition(first.text == markdown, "\(step): \(first.text.debugDescription)")
            precondition(window.firstResponder === view)
        }
        first.text = "alpha **bold**\n\nbeta"
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        await expect(.numbered, "1. alpha **bold**\n2. beta", "Numbered")
        precondition(first.session.selectedListKind == .numbered)
        await expect(.dashed, "- alpha **bold**\n- beta", "Dashed")
        await expect(.bulleted, "* alpha **bold**\n* beta", "Bulleted")
        await expect(.bulleted, "alpha **bold**\n\nbeta", "Choosing the current list style again")
        await expect(.dashed, "- alpha **bold**\n- beta", "Dashed again")
        await expect(nil, "alpha **bold**\n\nbeta", "Body")
        // Without real events every step since loading shares one undo group, so undo a single step.
        first.text = "- alpha **bold**\n- beta"
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        await expect(nil, "alpha **bold**\n\nbeta", "Body from a loaded list")
        view.undoManager?.undo()
        await settle()
        precondition(first.text == "- alpha **bold**\n- beta", "Undo list removal: \(first.text.debugDescription)")
        print("PASS: Paragraph Style lists convert, toggle back to body, keep inline formatting, and undo")

        first.text = "# Title"
        await settle()
        view.setSelectedRange(NSRange(location: 2, length: 0))
        await expect(.dashed, "- Title", "Heading to list")
        precondition(view.selectedRange().location == (view.string as NSString).range(of: "Title").location + 2,
                     "Caret must stay on the same text: \(view.selectedRange())")
        first.text = "> quoted"
        await settle()
        select("quoted")
        await expect(.bulleted, "> * quoted", "Quoted list")
        first.text = "```\ncode\n```"
        await settle()
        select("code")
        await settle()
        precondition(!first.session.canSetListKind)
        first.session.setListKind(.dashed)
        precondition(first.text == "```\ncode\n```", "Code blocks reject list styles")
        print("PASS: headings become list items, quotes keep their structure, code blocks are left alone")

        first.text = ""
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        first.session.setListKind(.numbered)
        await settle()
        view.insertText("x", replacementRange: view.selectedRange())
        await settle()
        // New text without a source block ends the file with a newline.
        precondition(first.text == "1. x\n", "List in an empty document: \(first.text.debugDescription)")
        for (typed, markdown) in [("* ", "* item\n"), ("- ", "- item\n")] {
            first.text = ""
            await settle()
            view.setSelectedRange(NSRange(location: 0, length: 0))
            for character in typed + "item" { view.insertText(String(character), replacementRange: view.selectedRange()) }
            await settle()
            precondition(first.text == markdown, "Typed \(typed.debugDescription): \(first.text.debugDescription)")
        }
        print("PASS: lists start in an empty document, and typed `*`/`-` pick bulleted/dashed")
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(300)) }
}
