import AppKit
import SwiftUI

/// Uses the editor's native find text view. Focus is requested explicitly, never by mounting.
struct FindInput: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let identifier: String
    let onSubmit: () -> Void
    let onDismiss: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> FindInputScrollView {
        let scroll = FindInputScrollView()
        let input = FindPanelTextView()
        input.font = FindBarContent.font
        input.autoresizingMask = [.width]
        input.drawsBackground = false
        input.textContainerInset = .zero
        input.string = text
        input.delegate = context.coordinator
        input.writingToolsCoordinator = .none
        input.writingToolsBehavior = .none
        input.placeholder = placeholder
        input.setAccessibilityPlaceholderValue(placeholder)
        input.setAccessibilityLabel(placeholder)
        input.setAccessibilityIdentifier(identifier)
        scroll.drawsBackground = false
        scroll.documentView = input
        return scroll
    }

    func updateNSView(_ scroll: FindInputScrollView, context: Context) {
        context.coordinator.parent = self
        guard let input = scroll.documentView as? FindPanelTextView else { return }
        if input.string != text {
            input.string = text
            input.needsDisplay = true
        }
        input.placeholder = placeholder
        input.action = onSubmit
        scroll.focusRequest = focusRequest
        scroll.applyFocusRequest()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: FindInputScrollView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: nsView.intrinsicContentSize.height)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: FindInput
        init(_ parent: FindInput) { self.parent = parent }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard commandSelector == #selector(NSResponder.cancelOperation(_:)) else { return false }
            parent.onDismiss()
            return true
        }
        func textDidChange(_ notification: Notification) {
            guard let input = notification.object as? NSTextView else { return }
            parent.text = input.string
        }
    }
}

final class FindInputScrollView: NSScrollView {
    var focusRequest = 0
    private var appliedFocusRequest = 0

    override var intrinsicContentSize: NSSize {
        guard let input = documentView as? NSTextView, let font = input.font else {
            return super.intrinsicContentSize
        }
        return NSSize(width: NSView.noIntrinsicMetric,
                      height: ceil(input.layoutManager?.defaultLineHeight(for: font) ?? (font.ascender - font.descender + font.leading)))
    }

    override func layout() {
        super.layout()
        documentView?.setFrameSize(NSSize(width: contentSize.width, height: intrinsicContentSize.height))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyFocusRequest()
    }

    func applyFocusRequest() {
        guard focusRequest != appliedFocusRequest, let window, let documentView else { return }
        appliedFocusRequest = focusRequest
        window.makeFirstResponder(documentView)
    }
}
