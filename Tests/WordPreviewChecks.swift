import AppKit
import SwiftUI
import QuickLookUI
@testable import TypeNBash

@main
struct WordPreviewChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        Task { @MainActor in
            do { try await run() } catch { fatalError("Word preview checks failed: \(error)") }
            exit(0)
        }
        app.run()
    }

    @MainActor static func run() async throws {
        AppDefaults.register()
        let text = NSAttributedString(string: "Native Word Preview\n\nLocal, read-only document viewing.\n",
                                      attributes: [.font: NSFont.systemFont(ofSize: 20)])
        let data = try text.data(from: NSRange(location: 0, length: text.length),
                                 documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        let limit = FileBrowserModel.binaryPreviewByteLimit
        var snapshot: WordPreviewDocument? = try WordPreviewDocument(data: data)
        let snapshotURL = snapshot!.url
        let snapshotData = try Data(contentsOf: snapshotURL)
        precondition(snapshotData == data)
        let permissions = try FileManager.default.attributesOfItem(atPath: snapshotURL.path)
        precondition((permissions[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        snapshot = nil
        precondition(!FileManager.default.fileExists(atPath: snapshotURL.deletingLastPathComponent().path))

        if case .failed = FileBrowserModel.makePreview(from: Data(), fileExtension: "docx", totalByteCount: 0, limit: limit) {} else {
            fatalError("Empty DOCX must not become editable text")
        }
        for (bytes, size) in [(data, Optional(limit + 1)), (Data(repeating: 0, count: limit + 1), nil)] {
            if case .unsupported = FileBrowserModel.makePreview(from: bytes, fileExtension: "docx", totalByteCount: size, limit: limit) {} else {
                fatalError("Oversized DOCX must not be passed to Quick Look")
            }
        }

        let fs = WordFixtureFileSystem(data: data)
        let model = FileBrowserModel(fileSystem: fs)
        model.select(WorkspaceFileEntry(url: fs.homeDirectory.appendingPathComponent("Sample.DOCX"), isDirectory: false, byteCount: nil))
        for _ in 0..<100 {
            if case .word = model.preview { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard case .word(let document) = model.preview else { fatalError("DOCX routing failed") }
        precondition(fs.requestedLimit == limit + 1)
        let previewData = try Data(contentsOf: document.url)
        precondition(previewData == data)
        model.updatePreviewText("Must not overwrite the document")
        model.save()
        precondition(!model.hasUnsavedChanges && !model.isSaving && fs.writes == 0)

        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let session = EditorSession()
        let host = NSHostingView(rootView: WorkspaceEditorPane(model: model, session: session).frame(width: 900, height: 650))
        let window = NSWindow(contentRect: NSRect(x: 100, y: 100, width: 900, height: 650),
                              styleMask: [.titled, .resizable, .closable], backing: .buffered, defer: false)
        window.title = "DOCX Viewer Verification"
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        defer { window.close() }
        try await Task.sleep(for: .seconds(4))
        func preview(in view: NSView) -> QLPreviewView? {
            if let view = view as? QLPreviewView { return view }
            return view.subviews.compactMap { preview(in: $0) }.first
        }
        guard let view = preview(in: host) else { fatalError("Native Quick Look view did not mount") }
        precondition(view.previewItem.previewItemURL == document.url)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "/tmp/centcom-docx-preview.png"))
        }
        print("PASS: DOCX routing, bounded reads, read-only save protection, private snapshot cleanup, and native Quick Look mounting")
        if ProcessInfo.processInfo.environment["WORD_PREVIEW_INSPECT"] == "1" {
            try await Task.sleep(for: .seconds(45))
        }
    }
}

@MainActor
private final class WordFixtureFileSystem: WorkspaceFileSystem {
    let homeDirectory = URL(fileURLWithPath: "/remote/documents")
    let data: Data
    var writes = 0
    var requestedLimit = 0
    init(data: Data) { self.data = data }
    func contentsOfDirectory(at directory: URL, includingHiddenFiles: Bool) async throws -> [WorkspaceFileEntry] { [] }
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        requestedLimit = maximumByteCount
        return Data(data.prefix(maximumByteCount))
    }
    func writeFile(_ data: Data, to url: URL) async throws { writes += 1 }
    func createDirectory(at url: URL) async throws {}
}
