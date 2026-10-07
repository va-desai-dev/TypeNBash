import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct FindFocusIntegrationChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.regular)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run() } catch { fatalError("Find focus checks: \(error)") }
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let pasteboard = NSPasteboard(name: .find)
        let previousFind = pasteboard.string(forType: .string)
        defer {
            pasteboard.clearContents()
            if let previousFind { pasteboard.setString(previousFind, forType: .string) }
        }
        let original = String(repeating: "Barnes cited Barrett. Barrett cited Barton.\n", count: 1_000)
        let model = FileBrowserModel()
        model.newFile()
        model.updatePreviewText(original)
        let session = EditorSession()
        let host = NSHostingView(rootView: WorkspaceEditorPane(model: model, session: session)
            .frame(width: 950, height: 550))
        // A separate native field also checks replace-and-find's responder
        // contract independently of SwiftUI's focus restoration.
        let replacement = NSTextField(string: "Replacement")
        let stack = NSStackView(views: [host, replacement])
        stack.orientation = .vertical
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 950, height: 590),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await settle()
        guard let document = session.textView else { fatalError("Editor did not mount") }
        TextFinderSettings.shared.findString = ""
        TextFinderSettings.shared.usesRegularExpression = false
        document.setSelectedRange(NSRange(location: 0, length: 0))
        session.find()
        try await settle()
        guard let findField = window.firstResponder as? NSTextView, findField !== document else {
            fatalError("Find field did not receive keyboard focus")
        }

        findField.insertText("Bar", replacementRange: findField.selectedRange())
        try await settle()
        precondition(document.selectedString == "Bar", "Incremental search must still select the match")
        precondition(window.firstResponder === findField, "Incremental search stole keyboard focus")
        (window.firstResponder as! NSTextView).insertText("rett", replacementRange: findField.selectedRange())
        try await settle()
        precondition(TextFinderSettings.shared.findString == "Barrett")
        precondition(document.string == original, "Continuing the query must not edit the document")
        precondition(window.firstResponder === findField)

        for action: TextFinder.Action in [.nextMatch, .previousMatch] {
            session.performFind(action)
            try await settle()
            precondition(document.selectedString == "Barrett")
            precondition(window.firstResponder === findField, "Match navigation stole focus")
        }

        window.makeFirstResponder(replacement)
        guard let replacementEditor = window.firstResponder as? NSTextView else { fatalError("No replacement field editor") }
        TextFinderSettings.shared.replacementString = "Replacement"
        session.performFind(.replaceAndFind)
        try await settle()
        precondition(window.firstResponder === replacementEditor, "Replace-and-find stole focus")
        precondition(document.string.contains("Replacement"))
        let afterReplace = document.string
        replacementEditor.insertText(" more", replacementRange: replacementEditor.selectedRange())
        try await settle()
        precondition(document.string == afterReplace, "Typing a replacement must not edit the next match")

        session.dismissFind()
        precondition(window.firstResponder === document, "Done should explicitly return focus to the editor")
        print("PASS: incremental Bar → Barrett query preserves document and focus; next/previous and replace-and-find preserve field focus; Done returns to editor")
    }

    static func settle() async throws { try await Task.sleep(for: .milliseconds(600)) }
}
