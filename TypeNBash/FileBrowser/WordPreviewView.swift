import SwiftUI
import QuickLookUI

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
