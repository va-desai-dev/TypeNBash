import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct MarkdownRichTextIntegrationChecks {
    // Keep synthetic mouse input independent of which app the user is working in.
    final class FixtureWindow: NSWindow {
        override var isKeyWindow: Bool { true }
    }
    @Observable final class Document {
        var text = "# Clipboard fixture\n\nA **bold** word and [link](https://example.com).\n\n| Name | Value |\n| --- | ---: |\n| One | 1 |"
        var focused = true
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
        var failures = 0
        func check(_ passed: Bool, _ message: String) {
            print("\(passed ? "PASS" : "FAIL"): \(message)")
            if !passed { failures += 1 }
        }
        let model = Document()
        let window = FixtureWindow(contentRect: NSRect(x: 80, y: 80, width: 800, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Fixture(document: model))
        window.makeKeyAndOrderFront(nil)
        await settle()
        guard let view = model.session.findTextView as? MarkdownRichTextView,
              let storage = view.textStorage, let layout = view.layoutManager, let container = view.textContainer else {
            fatalError("Rich editor failed to mount")
        }
        defer { window.close() }
        window.makeFirstResponder(view)
        check(type(of: layout) == NSLayoutManager.self, "Uses AppKit's native layout manager")
        let original = model.text
        check(view.document.markdown(from: storage) == original, "Untouched Markdown is byte-identical")
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }

        // AppKit's pasteboard negotiation must prefer RTF to its plain fallback.
        let rich = NSAttributedString(string: "Rich bold", attributes: [.font: NSFont.boldSystemFont(ofSize: 14)])
        board.declareTypes([.rtf, .string], owner: nil)
        board.setData(rich.rtf(from: NSRange(location: 0, length: rich.length), documentAttributes: [:])!, forType: .rtf)
        board.setString("Plain fallback", forType: .string)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        paste(board, into: view)
        check(view.string == "Rich bold", "RTF wins over plain text")
        check((storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont).map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "RTF bold survives paste")
        await settle()
        check(model.text.contains("**Rich bold**"), "Pasted RTF formatting survives Markdown serialization")

        model.text = "Body"
        await settle()
        board.declareTypes([.string], owner: nil)
        board.setString("**inline** and `code`", forType: .string)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        paste(board, into: view)
        check(view.string == "inline and code", "Single-line Markdown paste renders syntax: \(view.string.debugDescription)")
        await settle()
        check(model.text.contains("**inline** and `code`"), "Inline paste saves Markdown semantics: \(model.text.debugDescription)")
        let headingAttributes = view.document.render("# Heading").attributes(at: 0, effectiveRange: nil)
        let headingPaste = view.document.pastedMarkdown("*emphasis*", typingAttributes: headingAttributes)
        check((headingPaste.attribute(.font, at: 0, effectiveRange: nil) as? NSFont)?.pointSize == 26,
              "Plain Markdown pasted into a heading retains its font size")
        let codeAttributes = view.document.render("```swift\nlet x = 1\n```").attributes(at: 0, effectiveRange: nil)
        check(view.document.pastedMarkdown("**literal**", typingAttributes: codeAttributes).string == "**literal**",
              "Paste inside code preserves literal Markdown characters")

        model.text = original
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        check(view.writeSelection(to: board, types: view.writablePasteboardTypes), "Copy publishes rich text and Markdown")
        check(board.data(forType: .rtf) != nil, "Copy retains RTF for other apps")
        let copiedMarkdown = board.string(forType: .string)!
        paste(board, into: view)
        await settle()
        check(view.document.markdown(fragment: storage) == copiedMarkdown, "Internal copy retains headings, links and table alignment: \(view.document.markdown(fragment: storage).debugDescription)")
        layout.ensureLayout(for: container)

        // The final table has no following body paragraph in the source.
        model.text = "| Name | Value |\n| --- | ---: |\n| One | 1 |"
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        view.insertTab(nil)
        check((view.string as NSString).substring(with: view.selectedRange()) == "Value",
              "Tab with multiple cells selected navigates without creating overlapping rows")
        let lastCell = (view.string as NSString).range(of: "1", options: .backwards)
        view.setSelectedRange(NSRange(location: lastCell.location, length: 0))
        view.insertTab(nil)
        await settle()
        check(model.text.contains("|  |  |"), "Tab at document-ending table adds a complete empty row")
        layout.ensureLayout(for: container)
        view.undoManager?.undo()
        await settle()
        check(!model.text.contains("|  |  |"), "New table row is undoable")

        // Native RTF strips our custom table subclass; it must still serialize as a table.
        model.text = "| Name | Value |\n| --- | ---: |\n| One | 1 |"
        await settle()
        let rtf = storage.rtf(from: NSRange(location: 0, length: storage.length), documentAttributes: [:])!
        board.declareTypes([.rtf], owner: nil)
        board.setData(rtf, forType: .rtf)
        view.setSelectedRange(NSRange(location: 0, length: storage.length))
        paste(board, into: view)
        await settle()
        check(model.text.contains("| One | 1 |") && model.text.contains("---:"), "External RTF table retains grid and alignment on save")

        let large = "| Name | Value | Detail |\n| --- | ---: | --- |\n" + (0..<200).map { "| Row \($0) | \($0) | Some longer cell text that wraps in a narrow window |\n" }.joined()
        let start = CFAbsoluteTimeGetCurrent()
        model.text = large + "\nAfter the table.\n"
        await settle()
        check(view.undoManager?.canUndo != true, "External document reload clears obsolete undo actions")
        layout.ensureLayout(for: container)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        print("TIMING: 200-row table load + layout + 0.2s settle: \(elapsed)s")
        check(elapsed < 5, "200-row table lays out without a long stall")
        check(view.frame.height > 500 && view.enclosingScrollView?.documentView === view, "Text view grows beyond the viewport for native scrolling")
        view.setSelectedRange(NSRange(location: storage.length, length: 0))
        view.scrollRangeToVisible(view.selectedRange())
        await settle()
        check((view.enclosingScrollView?.contentView.bounds.minY ?? 0) > 0, "Native selection reveal scrolls to the document end")
        view.setSelectedRange(NSRange(location: 0, length: 20))
        view.scrollRangeToVisible(view.selectedRange())
        await settle()
        check((view.enclosingScrollView?.contentView.bounds.minY ?? 1) == 0, "Native selection reveal returns to the document start")
        check(model.text == large + "\nAfter the table.\n", "Layout and selection leave cached Markdown untouched")
        for _ in 0..<6 {
            let cellText = (view.string as NSString).range(of: "Some longer")
            view.setSelectedRange(cellText)
            view.insertText("Edited cell", replacementRange: cellText)
            layout.ensureLayout(for: container)
            await settle()
            view.undoManager?.undo()
            await settle()
            layout.ensureLayout(for: container)
        }
        check(model.text == large + "\nAfter the table.\n", "Repeated table edit, layout and undo preserve the source")

        model.text = "Drag selection fixture.\n\nSecond paragraph."
        await settle()
        view.setSelectedRange(NSRange(location: 0, length: 0))
        layout.ensureLayout(for: container)
        func point(at index: Int) -> NSPoint {
            let rect = view.firstRect(forCharacterRange: NSRange(location: index, length: 0), actualRange: nil)
            return window.convertPoint(fromScreen: NSPoint(x: rect.minX, y: rect.midY))
        }
        let startPoint = point(at: 0), endPoint = point(at: 14)
        func mouse(_ type: NSEvent.EventType, at point: NSPoint, number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                               context: nil, eventNumber: number, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)!
        }
        NSApp.postEvent(mouse(.leftMouseDragged, at: endPoint, number: 2), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: endPoint, number: 3), atStart: false)
        view.mouseDown(with: mouse(.leftMouseDown, at: startPoint, number: 1))
        check(view.selectedRange().length > 5, "Native mouse drag selects text")

        model.text = "| Name | Value |\n| --- | ---: |\n| One | 1 |\n| Two | 2 |"
        await settle()
        layout.ensureLayout(for: container)
        let tableSource = model.text
        let cellStart = point(at: (view.string as NSString).range(of: "One").location)
        let cellEnd = point(at: (view.string as NSString).range(of: "2").location + 1)
        NSApp.postEvent(mouse(.leftMouseDragged, at: cellEnd, number: 5), atStart: false)
        NSApp.postEvent(mouse(.leftMouseUp, at: cellEnd, number: 6), atStart: false)
        view.mouseDown(with: mouse(.leftMouseDown, at: cellStart, number: 4))
        check(view.selectedRange().length > 3, "Native mouse drag selects across table cells")
        view.insertText("Replacement", replacementRange: view.selectedRange())
        layout.ensureLayout(for: container)
        await settle()
        view.undoManager?.undo()
        await settle()
        layout.ensureLayout(for: container)
        check(model.text == tableSource, "Replacing a selection across table cells is undoable")
        precondition(failures == 0, "\(failures) rich editor checks failed")
    }
    @MainActor static func paste(_ board: NSPasteboard, into view: NSTextView) {
        let general = NSPasteboard.general
        let saved = (general.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        general.clearContents()
        for type in board.types ?? [] {
            if let data = board.data(forType: type) {
                general.addTypes([type], owner: nil)
                general.setData(data, forType: type)
            }
        }
        defer {
            general.clearContents()
            general.writeObjects(saved)
        }
        view.paste(nil)
    }
    static func settle() async { try? await Task.sleep(for: .milliseconds(200)) }
}
