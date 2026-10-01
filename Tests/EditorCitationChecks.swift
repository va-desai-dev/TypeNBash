import AppKit
import SwiftUI
import BibTeXViewer
import BibTeXKit
@testable import TypeNBash

@main
struct EditorCitationChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let text = "😀 [@known] [@missing] [see @known; -@other, p. 2] `[@ignored]` \\[@escaped]\n```md\n[@code]\n```\n    [@indented]\n[user@example.com] [@link](url)"
        let matches = EditorCitationMatch.find(in: text, keys: ["known", "other"])
        precondition(matches.map(\.matched) == [true, false, true])
        precondition(matches.map { (text as NSString).substring(with: $0.range) }
                     == ["[@known]", "[@missing]", "[see @known; -@other, p. 2]"])
        precondition(EditorCitationMatch.find(in: "~~~\n[@known]", keys: ["known"]).isEmpty)
        precondition(EditorCitationMatch.find(in: "[@Known]", keys: ["known"]).first?.matched == false)
        precondition(EditorCitationMatch.find(in: "[@known; @missing]", keys: ["known"]).first?.matched == false)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "CitationChecks.\(UUID())"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let first = root.appendingPathComponent("first.bib")
        let second = root.appendingPathComponent("second.bib")
        try "@book{known, title={Known}}".write(to: first, atomically: true, encoding: .utf8)
        try "@book{missing, title={Missing}}".write(to: second, atomically: true, encoding: .utf8)
        let library = BibLibrary(projectID: UUID(), root: root,
                                 selections: BibSelectionStore(defaults: defaults), inbox: nil)
        library.select(first)
        var contents = "[@known] [@missing]"
        let session = EditorSession()
        let bridge = CodeEditorTextView(text: Binding(get: { contents }, set: { contents = $0 }),
            fileURL: root.appendingPathComponent("paper.md"), options: EditorOptions(),
            session: session, comparesWithGit: false, bibliography: library)
        let host = NSHostingView(rootView: bridge)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(800))
        let view = session.textView!
        let layout = view.layoutManager as! LayoutManager
        func color(_ index: Int) -> NSColor? {
            layout.temporaryAttribute(.citationColor, atCharacterIndex: index, effectiveRange: nil) as? NSColor
        }
        precondition(color(0) == .systemGreen && color(9) == .systemRed)
        precondition(view.string == contents && view.undoManager?.canUndo != true)
        // Syntax recoloring must not erase citation status or its display override.
        layout.addTemporaryAttribute(.foregroundColor, value: NSColor.systemBlue,
                                     forCharacterRange: NSRange(location: 0, length: 8))
        session.syntaxController?.parseAll()
        try await Task.sleep(for: .milliseconds(300))
        let attributes = layout.temporaryAttributes(atCharacterIndex: 0, effectiveRange: nil)
        let display = layout.layoutManager(layout, shouldUseTemporaryAttributes: attributes,
            forDrawingToScreen: true, atCharacterIndex: 0, effectiveRange: nil)
        precondition(display?[.foregroundColor] as? NSColor == .systemGreen)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!
                .write(to: URL(fileURLWithPath: "/tmp/centcom-citation-highlights.png"))
        }

        library.select(second)
        try await Task.sleep(for: .milliseconds(600))
        precondition(color(0) == .systemRed && color(9) == .systemGreen)
        // Editing and undo use the real AppKit delegate path.
        window.makeFirstResponder(view)
        view.insertText("missing", replacementRange: NSRange(location: 2, length: 5))
        try await Task.sleep(for: .milliseconds(400))
        precondition(color(0) == .systemGreen && contents == "[@missing] [@missing]")
        view.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(400))
        precondition(color(0) == .systemRed && contents == "[@known] [@missing]")
        try "@book{known, title={Known}}\n@book{missing, title={Missing}}"
            .write(to: second, atomically: true, encoding: .utf8)
        library.reload()
        try await Task.sleep(for: .milliseconds(600))
        precondition(color(0) == .systemGreen && color(9) == .systemGreen)
        library.select(nil)
        try await Task.sleep(for: .milliseconds(250))
        precondition(color(0) == nil && color(9) == nil)
        print("Citation checks passed: UTF-16 ranges, groups, code exclusions, matching, library switching, syntax coexistence, editing, undo, and neutral state.")
    }
}
