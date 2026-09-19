//
//  GitDiffTextView.swift
//
//  TypeNBash
//
//  The comparison surface: the source editor itself, read-only.
//
//  This is deliberately not a text view of its own. It is `EditorTextView` —
//  the same ported CotEditor view the file preview uses — with the same theme,
//  the same tree-sitter highlighting, the same font and the same soft wrapping.
//  Only two things are spliced on top:
//
//  - the changed rows are banded using the editor's own
//    `.roundedBackgroundColor` temporary attribute, which `EditorTextView`
//    already draws, and which composes with syntax highlighting because that
//    is carried in separate temporary attributes (`.foregroundColor`); and
//  - the line-number ruler is swapped for one that shows both sides' numbers
//    and the change marker.
//
//  Keeping the marker in the ruler rather than in the text is the point of the
//  arrangement — a selection yields the file's own lines, so pasting a hunk
//  elsewhere needs no stripping of a leading `+`/`-` column.
//

import AppKit
import LineEnding
import SwiftUI
import SyntaxFormat

/// The SwiftUI leaf that hosts the diff text view and its gutter.
struct GitDiffTextPane: NSViewRepresentable {

    let rows: [GitDiffRow]
    /// The file being compared, for choosing the syntax. Its contents are never
    /// read — the comparison supplies the text, this only picks the grammar.
    let fileURL: URL?
    /// Identifies the comparison on screen. A new key means new content, which
    /// reloads the text and returns the scroll to the top.
    let contentKey: String

    @Environment(\.colorScheme) private var colorScheme
    @AppStorage("editor.tabWidth") private var tabWidth = 4

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        // The storage carries the comparison from the moment it exists.
        //
        // This is the whole reason the pane is rebuilt per comparison rather
        // than refilled: `textView.font` and `textView.theme` apply their
        // attributes to the storage as it stands when they are set, and
        // `applyTheme()` will not reapply a color it believes is already there.
        // Assigning `.string` afterwards replaces the characters and drops
        // those attributes, leaving glyphs with no color to draw in. Building
        // the storage first is exactly what the source editor does.
        let (text, starts) = Self.compose(rows)
        let textStorage = NSTextStorage(string: text)
        let scanner = LineEndingScanner(textStorage: textStorage, lineEnding: .lf)
        let textView = EditorTextView(textStorage: textStorage, lineEndingScanner: scanner)

        textView.usesRuler = true
        textView.font = CodeEditorTextView.editorFont
        textView.isEditable = false
        // Reading, not writing. The editing affordances have nothing to act on,
        // and the current-line highlight would sit on top of the row bands.
        textView.highlightsCurrentLines = true
        textView.highlightsBraces = false
        textView.highlightsSelectionInstance = false
        textView.showsInvisibles = true
        textView.showsIndentGuides = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false

        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true
        scrollView.borderType = .noBorder
        scrollView.contentView.automaticallyAdjustsContentInsets = true
        scrollView.documentView = textView
        let ruler = GitDiffRulerView(textView: textView, scrollView: scrollView)
        scrollView.verticalRulerView = ruler
        scrollView.autoresizingMask = [.width, .height]

        // Set the theme only after the text view is inside the scroll view:
        // `applyTheme()` asserts on `enclosingScrollView`.
        textView.theme = .TypeNBash(colorScheme)

        // Lines soft-wrap, exactly as they do in the editor — a comparison is
        // read top to bottom, and a horizontal scroller would hide the ends of
        // the very lines that changed.
        textView.wrapsLines = true
        textView.tabWidth = [2, 4, 8].contains(tabWidth) ? tabWidth : 4

        ruler.setRows(rows)
        context.coordinator.configureSyntax(for: fileURL, textView: textView)
        context.coordinator.band(rows: rows, starts: starts,
                                 totalLength: (text as NSString).length, in: textView)

        textStorage.delegate = context.coordinator
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorTextView else { return }

        // Only the theme: the comparison itself arrives as a new view, keyed on
        // `contentKey` by the caller.
        let theme = Theme.TypeNBash(colorScheme)
        if textView.theme != theme {
            textView.theme = theme
            context.coordinator.updateTheme(theme)
        }
    }

    /// Takes the size the layout proposes, whatever the document is.
    ///
    /// Without this, SwiftUI sizes the pane by asking the scroll view what it
    /// fits — and a scroll view answers with its document, so a long
    /// comparison asks for thousands of points of height. In a stack that
    /// claims every point of it and pushes the chrome off the window, which is
    /// what made an earlier version put the header and footer in safe-area
    /// bars instead.
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions(by: CGSize(width: 480, height: 320))
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.syntaxController?.cancel()
        (scrollView.documentView as? EditorTextView)?.textStorage?.delegate = nil
    }

    /// Joins the rows into the pane's text, with the UTF-16 offset each one
    /// starts at.
    ///
    /// The text is the file's own content — `right` where a line exists on the
    /// new side, `left` for removals — with no marker column, so that copying a
    /// selection gives back pastable source.
    private static func compose(_ rows: [GitDiffRow]) -> (text: String, starts: [Int]) {
        var text = ""
        var starts: [Int] = []
        starts.reserveCapacity(rows.count)
        var length = 0
        for (index, row) in rows.enumerated() {
            if index > 0 {
                text += "\n"
                length += 1
            }
            starts.append(length)
            let line = (row.right ?? row.left)?.text ?? ""
            text += line
            length += (line as NSString).length
        }
        return (text, starts)
    }


    // MARK: Coordinator

    @MainActor
    final class Coordinator: NSObject, NSTextStorageDelegate {

        private(set) var syntaxController: SyntaxController?
        private var syntaxName: String?
        private var theme: Theme?

        /// Washes the changed rows in the margin color.
        ///
        /// A plain `.backgroundColor` on the storage, which the layout manager
        /// draws with the glyphs it is already drawing.
        ///
        /// Not `.roundedBackgroundColor`: that one is drawn by
        /// `EditorTextView.drawBackground(in:)`, which resolves it through
        /// `boundingRects(for:)` — laying out line fragments from inside the
        /// draw pass. The editor gets away with it because nothing normally
        /// carries that attribute, so the work is skipped; a comparison puts
        /// one on every changed row, and the re-entrant layout costs the view
        /// its glyphs. That is the same trap as overriding `drawBackground`
        /// by hand: the gutter still paints, and the text does not.
        func band(rows: [GitDiffRow], starts: [Int], totalLength: Int,
                  in textView: EditorTextView) {
            guard let storage = textView.textStorage else { return }

            let whole = NSRange(location: 0, length: totalLength)
            storage.beginEditing()
            storage.removeAttribute(.backgroundColor, range: whole)

            for (index, row) in rows.enumerated() {
                guard let tint = row.diffTint else { continue }

                let start = starts[index]
                let end = (index + 1 < starts.count) ? starts[index + 1] - 1 : totalLength
                // A blank added or removed line has no glyphs to band, so it
                // takes in its line break instead — just enough to show that
                // something changed on it.
                let length = (end > start) ? end - start : min(1, totalLength - start)
                guard length > 0 else { continue }

                storage.addAttribute(.backgroundColor, value: tint,
                                     range: NSRange(location: start, length: length))
            }
            storage.endEditing()
        }

        /// Re-applies the theme colors to the existing highlights.
        func updateTheme(_ theme: Theme) {
            self.theme = theme
            guard let controller = self.syntaxController else { return }
            controller.theme = theme
            controller.parseAll()
        }

        /// (Re)builds the syntax controller when the compared file's language
        /// changes.
        func configureSyntax(for fileURL: URL?, textView: EditorTextView) {
            guard let textStorage = textView.textStorage else { return }

            let desiredName = fileURL.flatMap(SyntaxDefinition.syntaxName(for:))
            guard desiredName != self.syntaxName || self.syntaxController == nil else { return }

            self.syntaxController?.cancel()
            self.syntaxName = desiredName
            textStorage.apply(highlights: [], theme: nil,
                              in: NSRange(location: 0, length: textStorage.length))
            textView.applySyntax(Syntax())

            guard let (syntax, name) = SyntaxDefinition.load(for: fileURL) else {
                self.syntaxController = nil
                return
            }

            textView.applySyntax(syntax)
            let controller = SyntaxController(textStorage: textStorage, syntax: syntax, name: name)
            controller.theme = self.theme ?? textView.theme
            controller.setupParser()
            self.syntaxController = controller
        }

        // MARK: NSTextStorageDelegate

        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions,
                         range editedRange: NSRange, changeInLength delta: Int) {
            guard editedMask.contains(.editedCharacters) else { return }
            self.syntaxController?.invalidate(in: editedRange, changeInLength: delta)
        }
    }
}


// MARK: - Row Styling

extension GitDiffRow {

    /// The wash behind a row, or `nil` for unchanged context.
    var diffTint: NSColor? {
        if self.isHeader { return .secondaryLabelColor.withAlphaComponent(0.12) }
        if self.left?.changed == true { return .systemRed.withAlphaComponent(0.16) }
        if self.right?.changed == true { return .systemGreen.withAlphaComponent(0.16) }
        return nil
    }

    /// The gutter marker for a row, or `nil` for context and hunk headers.
    var diffMarker: (text: String, color: NSColor)? {
        guard !self.isHeader else { return nil }
        if self.left?.changed == true { return ("−", .systemRed) }
        if self.right?.changed == true { return ("+", .systemGreen) }
        return nil
    }
}


// MARK: - Ruler

/// The diff gutter: the old line number, the new line number, and a fixed
/// 10-point marker column, banded in the same color as its row.
///
/// It stands in for `LineNumberView` in the scroll view's ruler slot. The
/// editor's own gutter numbers a document's lines one after another, which is
/// exactly what a comparison cannot do — a row carries a number on one side, on
/// the other, or on both, and the two rarely agree.
final class GitDiffRulerView: NSRulerView {

    private static let markerWidth: CGFloat = 10
    private static let columnGap: CGFloat = 6
    private static let edgeInset: CGFloat = 6
    private static let minimumDigits = 3
    private static let font: NSFont = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)

    /// The displayed comparison. Row *n* is the text view's logical line *n+1*,
    /// which is how a line fragment finds its numbers again.
    private var rows: [GitDiffRow] = []

    private var numberWidth: CGFloat = 0
    private var observers: [NSObjectProtocol] = []

    init(textView: NSTextView, scrollView: NSScrollView) {
        super.init(scrollView: scrollView, orientation: .verticalRuler)

        self.clientView = textView
        self.reservedThicknessForMarkers = 0
        self.reservedThicknessForAccessoryView = 0
        self.invalidateLayout()
        self.observe(scrollView: scrollView, textView: textView)
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        self.observers.forEach(NotificationCenter.default.removeObserver)
    }

    /// Matches the text view, so line rects convert across without flipping.
    override var isFlipped: Bool {
        true
    }

    override func accessibilityLabel() -> String? {
        "Diff line numbers"
    }

    /// Scrolls the text view rather than the ruler alone.
    override func scrollWheel(with event: NSEvent) {
        self.clientView?.scrollWheel(with: event)
    }

    /// Replaces the comparison the gutter labels.
    func setRows(_ rows: [GitDiffRow]) {
        self.rows = rows
        self.invalidateLayout()
    }

    override func draw(_ dirtyRect: NSRect) {
        self.drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let textView = self.clientView as? NSTextView else { return }

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }

        // Clipped to the gutter. The rect a ruler is asked to draw reaches past
        // its own frame, and filling all of it paints the text view's
        // background over the text view itself — the ruler is drawn after the
        // document, so the glyphs go under it and the pane looks empty beside a
        // perfectly good gutter. `LineNumberView` guards the same way.
        if textView.drawsBackground {
            textView.backgroundColor.setFill()
            rect.intersection(self.bounds).fill()
        }

        guard let range = textView.range(for: textView.visibleRect) else { return }

        let numberAttributes: [NSAttributedString.Key: Any] = [
            .font: Self.font,
            .foregroundColor: (textView.textColor ?? .textColor).withAlphaComponent(0.55),
        ]
        let lineHeight = ("8" as NSString).size(withAttributes: numberAttributes).height
        let originOffset = textView.textContainerOrigin.y

        // One call per logical line, at its first fragment — so a soft-wrapped
        // row is numbered once, the way the editor's own gutter numbers it.
        textView.enumerateLineFragments(in: range, options: .bySkippingExtraLine) { lineRect, lineNumber, _ in
            guard lineNumber >= 1, lineNumber <= self.rows.count else { return }

            let row = self.rows[lineNumber - 1]
            let top = self.convert(NSPoint(x: 0, y: lineRect.minY + originOffset), from: textView).y

            if let tint = row.diffTint {
                tint.setFill()
                NSRect(x: 0, y: top, width: self.ruleThickness, height: lineRect.height)
                    .intersection(self.bounds).fill()
            }

            let baseline = top + (lineRect.height - lineHeight) / 2
            self.drawNumber(row.left?.number, right: self.oldNumberRight,
                            y: baseline, attributes: numberAttributes)
            self.drawNumber(row.right?.number, right: self.newNumberRight,
                            y: baseline, attributes: numberAttributes)

            if let marker = row.diffMarker {
                let text = marker.text as NSString
                let attributes: [NSAttributedString.Key: Any] = [
                    .font: Self.font, .foregroundColor: marker.color,
                ]
                let size = text.size(withAttributes: attributes)
                text.draw(at: NSPoint(x: self.markerOrigin + (Self.markerWidth - size.width) / 2,
                                      y: baseline),
                          withAttributes: attributes)
            }
        }
    }

    /// Re-measures the number columns and the resulting rule thickness.
    ///
    /// Called when the content changes, since the widest line number decides
    /// how much room the two number columns need.
    func invalidateLayout() {
        let widest = self.rows.reduce(0) { max($0, $1.left?.number ?? 0, $1.right?.number ?? 0) }
        let digits = max(String(widest).count, Self.minimumDigits)
        let digitWidth = ("8" as NSString).size(withAttributes: [.font: Self.font]).width
        self.numberWidth = (CGFloat(digits) * digitWidth).rounded(.up)

        let thickness = (self.markerOrigin + Self.markerWidth + Self.edgeInset).rounded(.up)
        if thickness != self.ruleThickness {
            self.ruleThickness = thickness
            // The scroll view only gives the document the room the ruler left
            // over at its last tiling, so a new thickness needs a re-tile or
            // the text keeps running underneath the gutter.
            self.scrollView?.tile()
        }
        self.needsDisplay = true
    }

    // MARK: Private Methods

    private var oldNumberRight: CGFloat {
        Self.edgeInset + self.numberWidth
    }

    private var newNumberRight: CGFloat {
        self.oldNumberRight + Self.columnGap + self.numberWidth
    }

    private var markerOrigin: CGFloat {
        self.newNumberRight + Self.columnGap
    }

    /// Draws a line number right-aligned to `right`.
    private func drawNumber(_ number: Int?, right: CGFloat, y: CGFloat,
                            attributes: [NSAttributedString.Key: Any]) {
        guard let number else { return }

        let text = String(number) as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(at: NSPoint(x: right - size.width, y: y), withAttributes: attributes)
    }

    /// Redraws the gutter as the text view scrolls or relayouts, which the
    /// ruler is not told about on its own.
    private func observe(scrollView: NSScrollView, textView: NSTextView) {
        scrollView.contentView.postsBoundsChangedNotifications = true
        textView.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        self.observers = [
            center.addObserver(forName: NSView.boundsDidChangeNotification,
                               object: scrollView.contentView, queue: .main) { [unowned self] _ in
                self.needsDisplay = true
            },
            center.addObserver(forName: NSView.frameDidChangeNotification,
                               object: textView, queue: .main) { [unowned self] _ in
                self.needsDisplay = true
            },
        ]
    }
}
