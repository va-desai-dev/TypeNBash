//
//  MarkdownEngineCitationHighlighter.swift
//  TypeNBash
//
//  CiteTex citation colors for the Markdown engine editor, by the same rule
//  as the code editor's `EditorCitationHighlighter`: a `[@key …]` bracket is
//  green when every key is in the project's .bib, red otherwise.
//
//  The engine's own seams can't express that. Directives only recognize
//  registered names, so an unknown key could never be marked, and an
//  extension's attributes never see its span's text. Instead this paints
//  TextKit 2 rendering attributes over the engine's text view — display
//  only, never touching the text, its styling, or undo.
//

import AppKit
import BibTeXKit
import BibTeXViewer
import Combine
import SwiftUI

struct MarkdownEngineCitationHighlighter: NSViewRepresentable {
    let library: BibLibrary?

    func makeNSView(context: Context) -> HighlighterView { HighlighterView() }

    func updateNSView(_ nsView: HighlighterView, context: Context) {
        nsView.library = library
    }

    final class HighlighterView: NSView {
        var library: BibLibrary? {
            didSet { if library !== oldValue { subscribe() } }
        }

        private weak var textView: NSTextView?
        private var keys: Set<String>?
        private var subscription: AnyCancellable?
        private var observers: [NSObjectProtocol] = []
        private var task: Task<Void, Never>?
        private var paintedText: String?
        private var paintedKeys: Set<String>?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observers.forEach(NotificationCenter.default.removeObserver)
            observers = []
            guard window != nil else {
                task?.cancel()
                return
            }
            // Typing, and the engine loading a document (which rebuilds its storage).
            observers.append(NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated { self?.textDidChange(note.object as? NSTextView) }
            })
            observers.append(NotificationCenter.default.addObserver(
                forName: NSTextStorage.didProcessEditingNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let storage = note.object as? NSTextStorage,
                          storage === self.engineTextView()?.textStorage else { return }
                    self.refresh()
                }
            })
            // The engine's view joins the window in the same pass as this one.
            DispatchQueue.main.async { [weak self] in self?.refresh() }
        }

        private func subscribe() {
            subscription = library?.$document.sink { [weak self] document in
                MainActor.assumeIsolated {
                    self?.keys = document?.keys
                    self?.refresh()
                }
            }
            if library == nil {
                keys = nil
                refresh()
            }
        }

        private func textDidChange(_ changed: NSTextView?) {
            guard let changed, changed === engineTextView() else { return }
            refresh()
        }

        /// Recolors after a short pause, off the main thread for the scan, as the code editor does.
        private func refresh() {
            guard let textView = engineTextView() else { return }
            let text = textView.string
            guard text != paintedText || keys != paintedKeys else { return }
            task?.cancel()
            // Always deferred: this can run from inside the engine's own storage edit.
            let keys = keys
            task = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                let matches = await Task.detached(priority: .utility) {
                    keys.map { EditorCitationMatch.find(in: text, keys: $0) } ?? []
                }.value
                guard !Task.isCancelled, let self, let view = self.engineTextView(),
                      view.string == text, self.keys == keys else { return }
                self.paint(matches, in: view, text: text)
            }
        }

        private func paint(_ matches: [EditorCitationMatch], in textView: NSTextView, text: String) {
            guard let layout = textView.textLayoutManager, let content = layout.textContentManager else { return }
            paintedText = text
            paintedKeys = keys
            func textRange(_ range: NSRange) -> NSTextRange? {
                guard let start = content.location(layout.documentRange.location, offsetBy: range.location),
                      let end = content.location(start, offsetBy: range.length) else { return nil }
                return NSTextRange(location: start, end: end)
            }
            layout.removeRenderingAttribute(.foregroundColor, for: layout.documentRange)
            for match in matches {
                guard let range = textRange(match.range) else { continue }
                layout.addRenderingAttribute(.foregroundColor,
                                             value: match.matched ? NSColor.systemGreen : NSColor.systemRed,
                                             for: range)
            }
        }

        /// The engine's text view beside this one: the nearest ancestor holding
        /// exactly one, so split panes each find their own editor.
        private func engineTextView() -> NSTextView? {
            if let textView, textView.window === window { return textView }
            var ancestor = superview
            while let view = ancestor {
                let found = Self.engineTextViews(in: view)
                if found.count == 1 {
                    textView = found[0]
                    return found[0]
                }
                if found.count > 1 { return nil }
                ancestor = view.superview
            }
            return nil
        }

        private static func engineTextViews(in view: NSView) -> [NSTextView] {
            if let textView = view as? NSTextView, String(describing: type(of: textView)) == "NativeTextView" {
                return [textView]
            }
            return view.subviews.flatMap { Self.engineTextViews(in: $0) }
        }
    }
}
