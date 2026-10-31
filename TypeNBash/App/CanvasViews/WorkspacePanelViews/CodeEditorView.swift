//
//  CodeEditor.swift
//
//  TypeNBash
//
//  A SwiftUI wrapper hosting CotEditor's `EditorTextView` (ported under
//  Editor/) in a scroll view with a line-number ruler, theme, and the
//  find panel. The heavy lifting — native selection, multi-cursor, invisibles,
//  find/replace, IME, accessibility — all comes from the ported text view.
//

import AppKit
import ColorCode
import LineEnding
import Invisible
import SyntaxFormat
import SwiftUI
import BibTeXViewer

/// The source editor behind the file preview pane.
struct CodeEditorTextView: NSViewRepresentable {

    @Binding var text: String
    var fileURL: URL?
    var options: EditorOptions
    var session: EditorSession
    var savedText: String? = nil
    var comparesWithGit = true
    var bibliography: BibLibrary? = nil
    var sourceNavigationID: UUID? = nil

    @Environment(\.colorScheme) private var colorScheme

    /// The app palette's editor colors for the current appearance.
    private var theme: Theme {
        AppTheme.shared.editorTheme(colorScheme)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, session: session)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let textStorage = NSTextStorage(string: text)
        let lineEnding = text.lineEndingRanges().majorValue() ?? .lf
        let scanner = LineEndingScanner(textStorage: textStorage, lineEnding: lineEnding)
        let textView = EditorTextView(textStorage: textStorage, lineEndingScanner: scanner)

        textView.delegate = context.coordinator
        textView.lineEnding = lineEnding
        textView.usesRuler = true
        textView.font = Self.editorFont
        textView.tabWidth = 4
        textView.isAutomaticTabExpansionEnabled = true
        textView.isAutomaticIndentEnabled = true
        textView.isAutomaticSymbolBalancingEnabled = true
        textView.highlightsCurrentLines = true
        textView.highlightsBraces = true
        textView.isEditable = true
        textView.shownInvisibles = Set(Invisible.allCases)
        textView.completionWordTypes = [.document, .syntax]
        textView.indentsWithTabKey = true
        textView.commentsOutAfterIndent = true
        textView.appendsCommentSpacer = true
        textView.highlightsSelectionInstance = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.smartInsertDeleteEnabled = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.borderType = .noBorder
        scrollView.contentView.automaticallyAdjustsContentInsets = true
        scrollView.documentView = textView
        let ruler = LineNumberView(
            textView: textView,
            scrollView: scrollView,
            orientation: .verticalRuler
        )
        ruler.diffColors = AppTheme.shared.diffColors
        scrollView.verticalRulerView = ruler
        scrollView.autoresizingMask = [.width, .height]

        // Set the theme only after the text view is inside the scroll view:
        // `applyTheme()` asserts on `enclosingScrollView`.
        textView.theme = theme

        options.apply(to: textView)
        context.coordinator.textView = textView
        session.markdownFinder?.detach()
        session.textView = textView
        textStorage.delegate = context.coordinator
        context.coordinator.configureSyntax(for: fileURL, textStorage: textStorage, theme: textView.theme)
        context.coordinator.updateSelection()
        context.coordinator.citations.configure(textView: textView, library: bibliography, fileURL: fileURL)
        context.coordinator.updateChanges(savedText: savedText ?? text, fileURL: comparesWithGit ? fileURL : nil)
        session.applySourceNavigation(to: textView, fileURL: fileURL)

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        context.coordinator.text = $text
        options.apply(to: textView)

        // Push external text changes in without disrupting local editing.
        if textView.string != text {
            let selection = textView.selectedRange()
            textView.string = text
            let length = (text as NSString).length
            let location = min(selection.location, length)
            textView.setSelectedRange(NSRange(location: location, length: min(selection.length, length - location)))
            textView.undoManager?.removeAllActions()
            let lineEnding = text.lineEndingRanges().majorValue() ?? .lf
            textView.lineEnding = lineEnding
            (textView.layoutManager as? LayoutManager)?.lineEndingScanner.baseLineEnding = lineEnding
            context.coordinator.syntaxController?.parseIfNeeded()
            context.coordinator.updateSelection()
        }

        let theme = self.theme
        if textView.theme != theme {
            textView.theme = theme
            context.coordinator.updateTheme(theme)
        }
        // The change bars share the diff pane's colors.
        (scrollView.verticalRulerView as? LineNumberView)?.diffColors = AppTheme.shared.diffColors

        // Follow the file's language if it changed.
        context.coordinator.configureSyntax(for: fileURL, textStorage: textView.textStorage, theme: theme)
        context.coordinator.citations.configure(textView: textView, library: bibliography, fileURL: fileURL)
        context.coordinator.updateChanges(savedText: savedText ?? context.coordinator.savedText,
                                          fileURL: comparesWithGit ? fileURL : nil)
        session.applySourceNavigation(to: textView, fileURL: fileURL)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.syntaxController?.cancel()
        coordinator.stopChanges()
        coordinator.citations.stop()
        coordinator.textView?.delegate = nil
        coordinator.textView?.textStorage?.delegate = nil
        coordinator.releaseSession()
    }

    /// SF Mono when available, falling back to the standard monospaced system face.
    ///
    /// Shared with the diff surface, which is this same text view read-only and
    /// has no business picking a face of its own.
    static let editorFont: NSFont = NSFont(name: "SFMono-Regular", size: 12)
        ?? .monospacedSystemFont(ofSize: 12, weight: .regular)


    // MARK: Coordinator

    final class Coordinator: NSObject, NSTextViewDelegate, NSTextStorageDelegate {

        var text: Binding<String>
        private let session: EditorSession
        weak var textView: EditorTextView?

        private(set) var syntaxController: SyntaxController?
        private var syntaxName: String?
        var theme: Theme?
        private let changeService = EditorChangeService()
        let citations = EditorCitationHighlighter()
        private var changeTask: Task<Void, Never>?
        private var changeFileURL: URL?
        private(set) var savedText = ""
        private var comparedText: String?

        init(text: Binding<String>, session: EditorSession) {
            self.text = text
            self.session = session
            super.init()
            NotificationCenter.default.addObserver(self, selector: #selector(refreshChanges),
                                                   name: NSApplication.didBecomeActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(refreshChanges),
                                                   name: .editorGitBaselineDidChange, object: nil)
        }

        func updateChanges(savedText: String, fileURL: URL?) {
            guard self.savedText != savedText || changeFileURL != fileURL || comparedText != textView?.string else { return }
            self.savedText = savedText
            changeFileURL = fileURL
            refreshChanges()
        }

        @objc private func refreshChanges() {
            changeTask?.cancel()
            guard let textView else { return }
            let contents = textView.string
            comparedText = contents
            let baseline = savedText, url = changeFileURL
            changeTask = Task { [weak self, changeService] in
                do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
                let changes = await changeService.changes(text: contents, savedText: baseline, fileURL: url)
                guard !Task.isCancelled, let self, self.ownsSession else { return }
                (self.textView?.enclosingScrollView?.verticalRulerView as? LineNumberView)?.lineChanges = changes
            }
        }

        func stopChanges() {
            changeTask?.cancel()
            NotificationCenter.default.removeObserver(self)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            updateSelection()
        }

        func updateSelection() {
            guard let textView, let scanner = (textView.layoutManager as? LayoutManager)?.lineEndingScanner else { return }
            let location = min(textView.selectedRange().location, scanner.length)
            let start = scanner.lineStartIndex(at: location)
            let column = (textView.string as NSString).substring(with: NSRange(start..<location)).count + 1
            let status = "Ln \(scanner.lineNumber(at: location)), Col \(column) · \(textView.lineEnding.label)"
            // AppKit can notify while SwiftUI is updating the representable.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ownsSession else { return }
                self.session.position = status
            }
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            self.text.wrappedValue = textView.string
            self.syntaxController?.parseIfNeeded()
            citations.refresh()
            refreshChanges()
            updateSelection()
        }

        // MARK: Syntax highlighting

        /// Re-applies the theme colors to the existing highlights.
        func updateTheme(_ theme: Theme) {
            self.theme = theme
            guard let controller = self.syntaxController else { return }
            controller.theme = theme
            controller.parseAll()
        }

        /// (Re)builds the syntax controller when the file's language changes.
        func configureSyntax(for fileURL: URL?, textStorage: NSTextStorage?, theme: Theme?) {
            self.theme = theme
            guard let textStorage else { return }

            let desiredName = fileURL.flatMap(SyntaxDefinition.syntaxName(for:))
            guard desiredName != self.syntaxName else { return }

            self.syntaxController?.cancel()
            self.syntaxName = desiredName
            textStorage.apply(highlights: [], theme: nil, in: NSRange(location: 0, length: textStorage.length))
            self.textView?.applySyntax(Syntax())

            guard let (syntax, name) = SyntaxDefinition.load(for: fileURL) else {
                self.syntaxController = nil
                publishSyntaxController()
                return
            }

            self.textView?.applySyntax(syntax)
            let controller = SyntaxController(textStorage: textStorage, syntax: syntax, name: name)
            controller.theme = theme
            controller.setupParser()
            self.syntaxController = controller
            publishSyntaxController()
        }

        /// Hands the shared session back when this editor goes away, so the
        /// header and footer stop reporting a text view that no longer exists.
        ///
        /// Deferred for the same reason as the other session writes — dismantle
        /// runs inside a SwiftUI update. Because switching files tears the old
        /// editor down and stands a new one up in the same pass, the deferred
        /// block can land after the replacement has already claimed the
        /// session; the identity check is what keeps it from clearing it.
        func releaseSession() {
            let retired = self.textView
            DispatchQueue.main.async { [session] in
                guard session.textView === retired else { return }
                session.textView = nil
                session.syntaxController = nil
                session.position = "Ln 1, Col 1"
            }
        }

        private func publishSyntaxController() {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.ownsSession else { return }
                self.session.syntaxController = self.syntaxController
            }
        }

        /// False once a newer editor has claimed the shared session, which is
        /// how the deferred writes above avoid reporting a retired editor's
        /// state over the live one's.
        private var ownsSession: Bool {
            self.session.textView === self.textView
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            self.syntaxController?.invalidate(in: editedRange, changeInLength: delta)
        }
    }
}


extension NSColor {

    /// Builds a color from a CSS-style color code, for pasting swatches straight
    /// out of Xcode's color picker or a published theme.
    ///
    /// Anything ColorCode understands works: `#RRGGBB`, `#RRGGBBAA`, `#RGB`,
    /// `#RGBA`, `rgb(…)`/`rgba(…)`, `hsl(…)`/`hsla(…)`, `hwb(…)`, or a CSS
    /// keyword. The leading `#` is optional.
    ///
    /// The components are reinterpreted in sRGB, which is what Xcode's picker,
    /// `.xccolortheme` files, and every web tool mean by a hex triplet.
    /// ColorCode hands back `calibratedRGB` for CotEditor's sake, and taking
    /// those numbers at face value in that space measurably shifts saturated
    /// hues — a pasted swatch would not match its source.
    ///
    /// Traps on a malformed code instead of silently substituting a default, so
    /// a typo surfaces the first time the theme is built. Only use this for
    /// literals compiled into the app — user-supplied themes should come in
    /// through `Theme`'s decoder, which degrades to `Style.invalid` rather than
    /// crashing on bad input.
    ///
    /// - Parameters:
    ///   - colorCode: The color code to parse.
    ///   - alpha: An opacity to apply on top of the parsed color.
    static func hex(_ colorCode: String, alpha: CGFloat = 1) -> NSColor {
        guard let color = sRGB(colorCode: colorCode, alpha: alpha) else {
            preconditionFailure("Invalid color code “\(colorCode)” in the TypeNBash theme.")
        }
        return color
    }

    /// The non-trapping form of `hex(_:alpha:)`, for codes read back from user
    /// defaults, where a bad value should fall back rather than crash.
    static func sRGB(colorCode: String, alpha: CGFloat = 1) -> NSColor? {
        // Try the code as written, then with the `#` that bare hex digits omit.
        guard let parsed = NSColor(colorCode: colorCode) ?? NSColor(colorCode: "#" + colorCode) else {
            return nil
        }

        // Re-tag, don't convert: the parsed components are already the sRGB
        // values the code names, just labelled with the wrong color space.
        return NSColor(srgbRed: parsed.redComponent,
                       green: parsed.greenComponent,
                       blue: parsed.blueComponent,
                       alpha: parsed.alphaComponent * alpha)
    }

    /// This color as an sRGB `#RRGGBBAA` code — the inverse of
    /// `sRGB(colorCode:)`, used to store theme overrides.
    var sRGBColorCode: String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let components = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent]
        // Extended-range components can fall outside 0...1; clamp before encoding.
        return "#" + components
            .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
            .joined()
    }
}
