import AppKit
import SwiftUI
@testable import TypeNBash

@MainActor
private final class RemoteSaveFixture: WorkspaceFileSystem {
    let homeDirectory: URL
    var fails = false
    var delays = false
    var pending: CheckedContinuation<Void, Error>?
    var writes = 0

    init(root: URL) { homeDirectory = root }
    func contentsOfDirectory(at url: URL, includingHiddenFiles: Bool) async throws -> [WorkspaceFileEntry] { [] }
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        Data(try Data(contentsOf: url).prefix(maximumByteCount))
    }
    func writeFile(_ data: Data, to url: URL) async throws {
        writes += 1
        if delays { try await withCheckedThrowingContinuation { pending = $0 } }
        if fails { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url)
    }
    func createDirectory(at url: URL) async throws {}
}

@main
struct RemoteFileSaveIntegrationChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fatalError("Remote save check failed: \(error)") }
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("remote-save-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fs = RemoteSaveFixture(root: root)
        let model = FileBrowserModel(fileSystem: fs)
        let session = EditorSession()
        let host = NSHostingView(rootView: WorkspaceEditorPane(model: model, session: session)
            .frame(width: 900, height: 500))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        func contents() -> String {
            switch model.preview {
            case .text(let text), .markdown(let text): return text
            default: preconditionFailure("Missing editable preview")
            }
        }
        func saveShortcut() {
            let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
                                        timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                        characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1)!
            precondition(window.performKeyEquivalent(with: event), "Mounted Save button must handle Command-S")
        }
        for ext in ["py", "md"] {
            let url = root.appendingPathComponent("remote file ' café.\(ext)")
            try Data((ext == "md" ? "# Remote file\n\nOriginal text\n" : "value = 1\n").utf8).write(to: url)
            model.select(WorkspaceFileEntry(url: url, isDirectory: false, byteCount: nil))
            try await waitFor { model.savedPreviewText.contains(ext == "md" ? "Original" : "value") }
            try await Task.sleep(for: .milliseconds(500))
            guard let textView = editor(in: host) else { preconditionFailure("Editor did not mount") }
            window.makeFirstResponder(textView)
            textView.insertText("\nEdited over SSH", replacementRange: NSRange(location: (textView.string as NSString).length, length: 0))
            try await waitFor { model.hasUnsavedChanges }
            let expected = contents()
            precondition(expected.contains("Edited over SSH"))
            try await Task.sleep(for: .milliseconds(150))
            let previousWrites = fs.writes
            saveShortcut()
            try await waitFor { fs.writes == previousWrites + 1 && !model.isSaving }
            let actual = try String(contentsOf: url, encoding: .utf8)
            precondition(actual == expected)
            precondition(!model.hasUnsavedChanges && model.saveError == nil)
            print("PASS: mounted \(ext) editor enables Save and Command-S writes through the remote filesystem")

            model.updatePreviewText(expected + " newer")
            fs.fails = true
            model.save()
            try await waitFor { !model.isSaving }
            precondition(model.hasUnsavedChanges && model.saveError != nil)
            let afterFailure = try String(contentsOf: url, encoding: .utf8)
            precondition(afterFailure == expected)
            fs.fails = false
            model.save()
            try await waitFor { !model.isSaving }
            precondition(!model.hasUnsavedChanges && model.saveError == nil)
        }
        let saved = contents()
        model.updatePreviewText(saved + " pending")
        fs.delays = true
        model.save()
        try await waitFor { fs.pending != nil }
        model.updatePreviewText(saved + " newer")
        fs.pending?.resume(); fs.pending = nil
        try await waitFor { !model.isSaving }
        precondition(model.hasUnsavedChanges && model.savedPreviewText == saved + " pending")
        model.updatePreviewText(model.savedPreviewText)
        precondition(!model.hasUnsavedChanges, "Returning to saved text clears the dirty state")
        fs.delays = false

        let large = root.appendingPathComponent("large.py")
        try Data(repeating: 65, count: FileBrowserModel.previewByteLimit + 1).write(to: large)
        model.select(WorkspaceFileEntry(url: large, isDirectory: false, byteCount: FileBrowserModel.previewByteLimit + 1))
        try await waitFor { model.isPreviewTruncated }
        let previousWrites = fs.writes
        model.updatePreviewText("must not overwrite a truncated file")
        model.save()
        precondition(fs.writes == previousWrites && model.saveError != nil)
        let localModel = FileBrowserModel()
        let localURL = root.appendingPathComponent("local.md")
        try Data("# Local file\n\nOriginal\n".utf8).write(to: localURL)
        localModel.select(WorkspaceFileEntry(url: localURL, isDirectory: false, byteCount: nil))
        try await waitFor { localModel.savedPreviewText.contains("Original") }
        host.rootView = WorkspaceEditorPane(model: localModel, session: session).frame(width: 900, height: 500)
        try await Task.sleep(for: .milliseconds(500))
        let localEditor = editor(in: host)!
        window.makeFirstResponder(localEditor)
        localEditor.insertText("Local edit", replacementRange: NSRange(location: (localEditor.string as NSString).length, length: 0))
        try await waitFor { localModel.hasUnsavedChanges }
        guard case .markdown(let localText) = localModel.preview else { preconditionFailure("Markdown preview lost") }
        try await Task.sleep(for: .milliseconds(150))
        saveShortcut()
        try await waitFor { !localModel.isSaving && !localModel.hasUnsavedChanges }
        let savedLocal = try String(contentsOf: localURL, encoding: .utf8)
        precondition(savedLocal == localText && savedLocal.contains("Local edit"))
        print("Save checks passed: local/SSH Markdown UI and Command-S, code regression, exact writes, failure/retry, edits during saves, truncation protection.")
    }

    @MainActor static func waitFor(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Save state timed out")
    }
}
