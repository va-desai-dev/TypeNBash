//
//  MarkdownEngineCaretFollower.swift
//  TypeNBash
//
//  Keeps the Markdown engine editor's caret on screen while typing.
//
//  At full width (no `readingWidth`), MarkdownEngine 0.15 hands caret reveal to
//  AppKit's `scrollRangeToVisible`. Inside the engine's container view that
//  never lays out the caret's line — TextKit 2 lays out lazily, so a line below
//  the viewport has a zero-size frame — and nothing scrolls. The engine's
//  reading-column path lays the line out first, which is why the Nodes app
//  (which uses a reading column) follows the caret. This does the same for
//  full width, from outside the engine.
//

import AppKit
import SwiftUI

struct MarkdownEngineCaretFollower: NSViewRepresentable {
    func makeNSView(context: Context) -> FollowerView { FollowerView() }
    func updateNSView(_ nsView: FollowerView, context: Context) {}

    final class FollowerView: NSView {
        private var observers: [NSObjectProtocol] = []
        /// The previous selection, to tell which end a keyboard extension moved.
        private var lastSelection = NSRange(location: NSNotFound, length: 0)

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else { return }
            for name in [NSTextView.didChangeSelectionNotification, NSText.didChangeNotification] {
                observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    MainActor.assumeIsolated { self?.follow(note.object as? NSTextView) }
                })
            }
        }

        /// Only the engine's own text view, in this window, while it has focus —
        /// so scrolling away with the trackpad is never pulled back.
        private func follow(_ textView: NSTextView?) {
            guard let textView, textView.window === window, window?.firstResponder === textView,
                  String(describing: type(of: textView)) == "NativeTextView"
            else { return }
            let selection = textView.selectedRange()
            defer { lastSelection = selection }
            // A selection made with the mouse is already where the user is looking,
            // and during a drag AppKit's autoscroll owns the scroll position:
            // revealing the selection's start there yanks the view back to it.
            guard !Self.isMouseDriven else { return }
            // Follow the end that moved: shift-down extends the end, shift-up the start.
            let caret = selection.length > 0 && selection.location == lastSelection.location
                ? NSMaxRange(selection) : selection.location
            // After the engine's restyle for this edit has settled the layout.
            DispatchQueue.main.async { Self.reveal(caret, in: textView) }
        }

        private static var isMouseDriven: Bool {
            if NSEvent.pressedMouseButtons != 0 { return true }
            switch NSApp.currentEvent?.type {
            case .leftMouseDown, .leftMouseDragged, .leftMouseUp,
                 .rightMouseDown, .rightMouseDragged, .rightMouseUp,
                 .otherMouseDown, .otherMouseDragged, .otherMouseUp,
                 .periodic, .scrollWheel:
                return true
            default:
                return false
            }
        }

        static func reveal(_ caret: Int, in textView: NSTextView) {
            guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
            let length = (textView.string as NSString).length
            // A caret at the very end has no fragment of its own; use the last character's.
            let offset = min(caret, max(length - 1, 0))
            guard let location = content.location(layout.documentRange.location, offsetBy: offset) else { return }
            layout.ensureLayout(for: NSTextRange(location: location))
            guard let fragment = layout.textLayoutFragment(for: location) else { return }
            let frame = fragment.layoutFragmentFrame
            // Reveal the caret's line, not its whole paragraph.
            var rect = frame
            let inFragment = content.offset(from: fragment.rangeInElement.location, to: location)
            let lines = fragment.textLineFragments
            if let index = lines.firstIndex(where: { $0.characterRange.contains(inFragment) }) ?? lines.indices.last {
                rect = lines[index].typographicBounds.offsetBy(dx: frame.minX, dy: frame.minY)
                // A paragraph's first line also brings its spacing above into view.
                if index == lines.startIndex { rect = rect.union(NSRect(x: rect.minX, y: frame.minY, width: rect.width, height: 0)) }
            }
            let origin = textView.textContainerOrigin
            textView.scrollToVisible(rect.offsetBy(dx: origin.x, dy: origin.y).insetBy(dx: 0, dy: -8))
        }
    }
}
