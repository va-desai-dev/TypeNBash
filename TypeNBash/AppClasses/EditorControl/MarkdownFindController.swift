import AppKit
import SwiftUI

/// Runs the code editor's TextFinder against a Markdown view that isn't an
/// `EditorTextView`: the Formatted rich-text editor, or the engine's editor.
final class MarkdownFindController {
    weak var textView: NSTextView?
    private weak var session: EditorSession?
    private let textFinder = TextFinder()
    private var keyMonitor: Any?
    private var resultObserver: NotificationCenter.ObservationToken?

    func attach(to textView: NSTextView, session: EditorSession) {
        guard self.textView !== textView else { return }
        detach()
        self.textView = textView
        self.session = session
        textFinder.client = textView
        session.markdownFinder = self
        session.textView = nil
        session.syntaxController = nil
        // At full width the engine's TextKit 2 view leaves reveal to AppKit, which never lays
        // out an off-screen line; scroll as the caret follower does, then re-point the indicator.
        resultObserver = NotificationCenter.default.addObserver(for: TextFinder.DidFindMessage.self) { [weak self] message in
            guard let view = self?.textView, view.textLayoutManager != nil, message.clientIdentifier == ObjectIdentifier(view),
                  let range = message.result.matchedRange else { return }
            MarkdownEngineCaretFollower.FollowerView.reveal(range.location, in: view)
            view.showFindIndicator(for: range)
        }
        // Neither view is a TextFinderClient, so ⌘F/⌘G stop at it.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                guard let self, let view = self.textView, event.window === view.window,
                      view.window?.firstResponder === view, !view.hasMarkedText() else { return false }
                let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
                let key = event.charactersIgnoringModifiers?.lowercased()
                if modifiers == .command, key == "f" { self.session?.find(); return true }
                if key == "g", modifiers == .command || modifiers == [.command, .shift] {
                    self.perform(modifiers.contains(.shift) ? .previousMatch : .nextMatch)
                    return true
                }
                return false
            }
            return handled ? nil : event
        }
        if session.isFindBarPresented { incrementalSearch() }
    }

    func detach() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        resultObserver = nil
        textView?.unhighlight(nil)
        if session?.markdownFinder === self { session?.markdownFinder = nil }
        textFinder.client = nil
        textView = nil
        session = nil
    }

    func perform(_ action: TextFinder.Action) { textFinder.performAction(action) }

    func incrementalSearch() { textFinder.incrementalSearch() }
}

/// Locates the native editor covered by this background. SwiftUI can flatten
/// split panes into one ancestor, so matching also uses the scroll view frame.
struct MarkdownFindBridge: NSViewRepresentable {
    let finder: MarkdownFindController
    let session: EditorSession

    func makeNSView(context: Context) -> BridgeView { BridgeView(finder: finder, session: session) }
    func updateNSView(_ nsView: BridgeView, context: Context) {}
    static func dismantleNSView(_ nsView: BridgeView, coordinator: ()) {
        DispatchQueue.main.async { nsView.finder.detach() }
    }

    final class BridgeView: NSView {
        let finder: MarkdownFindController
        let session: EditorSession

        init(finder: MarkdownFindController, session: EditorSession) {
            self.finder = finder
            self.session = session
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.window != nil else { self.finder.detach(); return }
                var ancestor = self.superview
                while let view = ancestor {
                    let editors = Self.editors(in: view).filter { editor in
                        guard let scroll = editor.enclosingScrollView else { return false }
                        return self.bounds.insetBy(dx: 1, dy: 1).intersects(self.convert(scroll.bounds, from: scroll))
                    }
                    if editors.count == 1 {
                        self.finder.attach(to: editors[0], session: self.session)
                        return
                    }
                    if editors.count > 1 { return }
                    ancestor = view.superview
                }
            }
        }

        private static func editors(in view: NSView) -> [NSTextView] {
            if let text = view as? NSTextView, String(describing: type(of: text)) == "NativeTextView" { return [text] }
            return view.subviews.flatMap { editors(in: $0) }
        }
    }
}
