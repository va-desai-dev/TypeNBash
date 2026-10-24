import Foundation
import SwiftUI
import QuickLookUI

/// Quick Look needs a local URL. Own an isolated snapshot for both local and SSH
/// files, keeping the source untouched and removing the snapshot on release.
nonisolated final class WordPreviewDocument: Sendable {
    let url: URL
    private let directory: URL

    init(data: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeNBash-Word-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("Document.docx")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}

/// Embed the system's read-only document preview without an office runtime.
struct WordPreviewView: NSViewRepresentable {
    let document: WordPreviewDocument

    func makeCoordinator() -> Coordinator { Coordinator(document: document) }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal)!
        view.shouldCloseWithWindow = false
        view.previewItem = document.url as NSURL
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        guard context.coordinator.document?.url != document.url else { return }
        view.previewItem = document.url as NSURL
        context.coordinator.document = document
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
        coordinator.document = nil
    }

    final class Coordinator {
        // Keep the snapshot alive until Quick Look releases its preview item.
        var document: WordPreviewDocument?
        init(document: WordPreviewDocument) { self.document = document }
    }
}
