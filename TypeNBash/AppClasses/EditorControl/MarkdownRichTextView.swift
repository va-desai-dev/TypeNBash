import AppKit
import MarkdownEngine

/// Inline formatting carried by attributes rather than the font, so it can't live
/// in `NSFontTraitMask`. Serializes as `~~…~~`, `==…==` and `` `…` ``.
struct MarkdownTextDecoration: OptionSet {
    let rawValue: Int
    static let strikethrough = MarkdownTextDecoration(rawValue: 1 << 0)
    static let highlight = MarkdownTextDecoration(rawValue: 1 << 1)
    static let code = MarkdownTextDecoration(rawValue: 1 << 2)
}

/// The Formatted view's text view: rich text that edits like Notes, on TextKit 1
/// so tables are real `NSTextTable` cells. Markdown appears only on the way in
/// (load, paste) and out (the file, the plain-text copy).
final class MarkdownRichTextView: NSTextView {
    var document: MarkdownRichText!

    /// Return turns a typed fence or rule into its block, leaves an empty quote or
    /// code line, and starts body text after a heading or rule.
    override func insertNewline(_ sender: Any?) {
        if let line = caretLine {
            let content = (string as NSString).substring(with: Self.trimmed(line.paragraph, in: string as NSString))
            if line.isBody, line.head == content,
               content.range(of: #"^(```|~~~)[\w+-]*$"#, options: .regularExpression) != nil {
                reformat(line.paragraph, removing: (content as NSString).length, as: content + "\nX\n" + content.prefix(3))
                return
            }
            if line.isBody, line.head == content, ["---", "***", "___"].contains(content) {
                reformat(line.paragraph, removing: 3, as: "---")
            } else if content.isEmpty, line.style.textBlocks.contains(where: { $0 is MarkdownQuoteBlock || $0 is MarkdownCodeBlock }) {
                reformat(line.paragraph, removing: 0, as: "X")
                return
            }
        }
        super.insertNewline(sender)
        guard typingAttributes[.markdownRole] != nil, let storage = textStorage else { return }
        var body = document.bodyAttributes
        body[.markdownChunk] = typingAttributes[.markdownChunk]
        let paragraph = (string as NSString).paragraphRange(for: selectedRange())
        if paragraph.length <= 1, shouldChangeText(in: paragraph, replacementString: nil) {
            storage.setAttributes(body, range: paragraph)
            didChangeText()
        }
        typingAttributes = body
    }

    // MARK: Markdown typed into rich text

    override func insertText(_ string: Any, replacementRange: NSRange) {
        super.insertText(string, replacementRange: replacementRange)
        guard !hasMarkedText(), let typed = (string as? String) ?? (string as? NSAttributedString)?.string,
              typed.count == 1 else { return }
        if typed == " " {
            formatBlockPrefix()
        } else if "*_~=`$])".contains(typed) {
            formatInline()
        }
    }

    private struct CaretLine {
        let paragraph: NSRange
        /// The paragraph's text from its start to the caret.
        let head: String
        let style: NSParagraphStyle
        let attributes: [NSAttributedString.Key: Any]
        var isBody: Bool { style.textBlocks.isEmpty && style.textLists.isEmpty && attributes[.markdownRole] == nil }
    }

    private var caretLine: CaretLine? {
        guard let storage = textStorage, selectedRange().length == 0 else { return nil }
        let text = string as NSString
        let caret = selectedRange().location
        let paragraph = text.paragraphRange(for: NSRange(location: caret, length: 0))
        let attributes = paragraph.length > 0 && paragraph.location < storage.length
            ? storage.attributes(at: paragraph.location, effectiveRange: nil) : typingAttributes
        return CaretLine(paragraph: paragraph,
                         head: text.substring(with: NSRange(location: paragraph.location, length: caret - paragraph.location)),
                         style: attributes[.paragraphStyle] as? NSParagraphStyle ?? .default,
                         attributes: attributes)
    }

    private static func trimmed(_ paragraph: NSRange, in text: NSString) -> NSRange {
        var range = paragraph
        while range.length > 0, [0x0A, 0x0D, 0x2029].contains(text.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        return range
    }

    /// `# `, `> `, `- `, `1. ` at the start of a body line become that block.
    private func formatBlockPrefix() {
        guard let line = caretLine, line.isBody,
              line.head.range(of: #"^(#{1,6}|>|[-*+]|\d{1,9}[.)]) $"#, options: .regularExpression) != nil else { return }
        reformat(line.paragraph, removing: (line.head as NSString).length, as: line.head + "X")
    }

    /// Gives `paragraph` the block formatting `markdown` renders with, replacing its
    /// first `prefix` characters with the rendered marker (a list bullet, or nothing).
    /// `X` in `markdown` marks where the paragraph's own text goes; without one the
    /// rendering replaces the text (a rule).
    private func reformat(_ paragraph: NSRange, removing prefix: Int, as markdown: String) {
        guard let storage = textStorage else { return }
        let sample = markdown == "X" ? NSAttributedString(string: "X", attributes: document.bodyAttributes) : document.render(markdown)
        let placeholder = (sample.string as NSString).range(of: "X", options: .backwards)
        let marker = placeholder.location == NSNotFound ? sample : sample.attributedSubstring(from: NSRange(location: 0, length: placeholder.location))
        var attributes = placeholder.location == NSNotFound ? document.bodyAttributes : sample.attributes(at: placeholder.location, effectiveRange: nil)
        let chunk = storage.length > 0 ? storage.attribute(.markdownChunk, at: min(paragraph.location, storage.length - 1), effectiveRange: nil) : nil
        attributes[.markdownChunk] = chunk
        let replacement = NSMutableAttributedString(attributedString: marker)
        let rest = placeholder.location == NSNotFound
            ? NSRange(location: NSMaxRange(Self.trimmed(paragraph, in: string as NSString)), length: NSMaxRange(paragraph) - NSMaxRange(Self.trimmed(paragraph, in: string as NSString)))
            : NSRange(location: paragraph.location + prefix, length: paragraph.length - prefix)
        let restStart = replacement.length
        replacement.append(storage.attributedSubstring(from: rest))
        let blockKeys: [NSAttributedString.Key] = [.paragraphStyle, .markdownRole, .foregroundColor]
        replacement.enumerateAttributes(in: NSRange(location: restStart, length: replacement.length - restStart)) { runAttributes, range, _ in
            var merged = runAttributes
            for key in blockKeys { merged[key] = attributes[key] }
            // Headings and code set the font; leaving one restores the body font.
            if [attributes, runAttributes].contains(where: {
                $0[.markdownRole] != nil || ($0[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is MarkdownCodeBlock
            }) {
                merged[.font] = attributes[.font]
            }
            replacement.setAttributes(merged, range: range)
        }
        if let chunk { replacement.addAttribute(.markdownChunk, value: chunk, range: NSRange(location: 0, length: replacement.length)) }
        replace(paragraph, with: replacement)
        setSelectedRange(NSRange(location: paragraph.location + marker.length, length: 0))
        typingAttributes = attributes
    }

    /// One undo step, so ⌘Z brings back exactly what was typed.
    private func replace(_ range: NSRange, with replacement: NSAttributedString) {
        guard let storage = textStorage else { return }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: replacement.string) else { return }
        storage.replaceCharacters(in: range, with: replacement)
        didChangeText()
        breakUndoCoalescing()
    }

    private enum InlineStyle { case bold, italic, strike, highlight }

    /// Closing a span renders it: emphasis keeps any formatting already inside it;
    /// code, math, wiki links and links render from their source.
    private static let inlineRules: [(NSRegularExpression, delimiter: Int, style: InlineStyle?)] = [
        (#"(?<!\*)\*\*([^*\s]|[^*\s][^*]*[^*\s])\*\*$"#, 2, .bold),
        (#"(?<![_\w])__([^_\s]|[^_\s][^_]*[^_\s])__$"#, 2, .bold),
        (#"(?<![*\w])\*([^*\s]|[^*\s][^*]*[^*\s])\*$"#, 1, .italic),
        (#"(?<![_\w])_([^_\s]|[^_\s][^_]*[^_\s])_$"#, 1, .italic),
        (#"~~([^~\s]|[^~\s][^~]*[^~\s])~~$"#, 2, .strike),
        (#"==([^=\s]|[^=\s][^=]*[^=\s])==$"#, 2, .highlight),
        (#"`[^`]+`$"#, 0, nil),
        (#"(?<![\\$])\$[^$\s](?:[^$]*[^$\s])?\$$"#, 0, nil),
        (#"\[\[[^\]]+\]\]$"#, 0, nil),
        (#"!?\[[^\]]*\]\([^)\s]+\)$"#, 0, nil),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1, $0.2) }

    private func formatInline() {
        guard let line = caretLine, let storage = textStorage,
              !(line.style.textBlocks.last is MarkdownCodeBlock) else { return }
        let head = line.head as NSString
        for (rule, delimiter, style) in Self.inlineRules {
            guard let found = rule.firstMatch(in: line.head, range: NSRange(location: 0, length: head.length)) else { continue }
            let match = NSRange(location: line.paragraph.location + found.range.location, length: found.range.length)
            let base = storage.attributes(at: match.location, effectiveRange: nil)
            guard base[.markdownSpan] as? String != "code" else { return }
            let replacement: NSMutableAttributedString
            if let style {
                replacement = NSMutableAttributedString(attributedString: storage.attributedSubstring(
                    from: NSRange(location: match.location + delimiter, length: match.length - 2 * delimiter)))
                let all = NSRange(location: 0, length: replacement.length)
                switch style {
                case .bold, .italic:
                    if style == .bold { replacement.addAttribute(.markdownStrong, value: true, range: all) }
                    replacement.enumerateAttribute(.font, in: all) { font, range, _ in
                        guard let font = font as? NSFont else { return }
                        replacement.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: style == .bold ? .boldFontMask : .italicFontMask), range: range)
                    }
                case .strike:
                    replacement.addAttributes(decorationAttributes(.strikethrough), range: all)
                case .highlight:
                    replacement.addAttributes(decorationAttributes(.highlight), range: all)
                }
            } else {
                let source = (string as NSString).substring(with: match)
                let rendered = document.render(source)
                guard rendered.string != source else { return }
                replacement = NSMutableAttributedString()
                rendered.enumerateAttributes(in: NSRange(location: 0, length: rendered.length)) { attributes, range, _ in
                    var merged = base
                    if attributes[.markdownSpan] as? String == "code" {
                        merged[.font] = document.codeFont
                    } else if let font = attributes[.font] as? NSFont, let baseFont = base[.font] as? NSFont {
                        merged[.font] = NSFontManager.shared.convert(baseFont, toHaveTrait: NSFontManager.shared.traits(of: font).intersection([.boldFontMask, .italicFontMask]))
                    }
                    for key: NSAttributedString.Key in [.link, .markdownSpan, .attachment, .backgroundColor, .strikethroughStyle, .strikethroughColor, .markdownHighlight] {
                        merged[key] = attributes[key] ?? merged[key]
                    }
                    if attributes[.markdownSpan] != nil, attributes[.markdownSpan] as? String != "code" { merged[.foregroundColor] = attributes[.foregroundColor] }
                    replacement.append(NSAttributedString(string: (rendered.string as NSString).substring(with: range), attributes: merged))
                }
            }
            replace(match, with: replacement)
            setSelectedRange(NSRange(location: match.location + replacement.length, length: 0))
            typingAttributes = base
            return
        }
    }

    override func insertTab(_ sender: Any?) {
        if !moveToCell(forward: true) { super.insertTab(sender) }
    }

    override func insertBacktab(_ sender: Any?) {
        if !moveToCell(forward: false) { super.insertBacktab(sender) }
    }

    /// Selects the next or previous cell's text; Tab in the last cell adds a row.
    private func moveToCell(forward: Bool) -> Bool {
        let text = string as NSString
        guard let storage = textStorage, storage.length > 0 else { return false }
        // A selection may span cells. Anchor navigation to its first paragraph;
        // treating the whole selection as a cell can insert overlapping row indices.
        let here = text.paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        func cell(at paragraph: NSRange) -> NSTextTableBlock? {
            guard paragraph.location < storage.length else { return nil }
            return (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        guard let current = cell(at: here), let table = current.table as? MarkdownTable else { return false }
        var paragraph = here
        var rowEnd = NSMaxRange(here)
        while true {
            let next = forward ? NSMaxRange(paragraph) : paragraph.location - 1
            guard next >= 0, next < storage.length else { break }
            paragraph = text.paragraphRange(for: NSRange(location: next, length: 0))
            guard let block = cell(at: paragraph), block.table === table else { break }
            rowEnd = NSMaxRange(paragraph)
            if block !== current {
                var content = paragraph
                if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
                setSelectedRange(content)
                return true
            }
        }
        guard forward else { return true }
        // Past the last cell: a new empty row after it.
        let row = current.startingRow + 1
        let cells = NSMutableAttributedString()
        for column in 0..<table.numberOfColumns {
            var attributes = document.cellAttributes(table, row: row, column: column)
            attributes[.markdownChunk] = storage.attribute(.markdownChunk, at: here.location, effectiveRange: nil)
            cells.append(NSAttributedString(string: "\n", attributes: attributes))
        }
        let insertion = NSRange(location: rowEnd, length: 0)
        guard shouldChangeText(in: insertion, replacementString: cells.string) else { return true }
        storage.replaceCharacters(in: insertion, with: cells)
        didChangeText()
        setSelectedRange(NSRange(location: rowEnd, length: 0))
        return true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self,
              event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers {
        case "b": setFontTrait(.boldFontMask, enabled: !selectedFontTraits.contains(.boldFontMask)); return true
        case "i": setFontTrait(.italicFontMask, enabled: !selectedFontTraits.contains(.italicFontMask)); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    /// A mixed selection shows a trait as off; enabling it formats every run.
    var selectedFontTraits: NSFontTraitMask {
        let manager = NSFontManager.shared
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            return (typingAttributes[.font] as? NSFont).map { manager.traits(of: $0) } ?? []
        }
        var traits: NSFontTraitMask = [.boldFontMask, .italicFontMask]
        storage.enumerateAttribute(.font, in: range) { font, _, _ in
            traits.formIntersection((font as? NSFont).map { manager.traits(of: $0) } ?? [])
        }
        return traits
    }

    func setFontTrait(_ trait: NSFontTraitMask, enabled: Bool) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            if trait == .boldFontMask { typingAttributes[.markdownStrong] = enabled }
            if let font = typingAttributes[.font] as? NSFont {
                typingAttributes[.font] = enabled
                    ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait)
            }
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if trait == .boldFontMask { storage.addAttribute(.markdownStrong, value: enabled, range: range) }
        storage.enumerateAttribute(.font, in: range) { font, subrange, _ in
            guard let font = font as? NSFont else { return }
            storage.addAttribute(.font, value: enabled ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func decorationAttributes(_ decoration: MarkdownTextDecoration) -> [NSAttributedString.Key: Any] {
        switch decoration {
        case .highlight: [.markdownHighlight: true, .backgroundColor: document.theme.highlightColor]
        case .code: [.markdownSpan: "code", .font: document.codeFont, .backgroundColor: MarkdownEngineCodeHighlighter.shared.backgroundColor()]
        default: [.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: document.theme.strikethroughColor]
        }
    }

    private static func decorations(in attributes: [NSAttributedString.Key: Any]) -> MarkdownTextDecoration {
        var decorations: MarkdownTextDecoration = []
        if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { decorations.insert(.strikethrough) }
        if attributes[.markdownHighlight] != nil { decorations.insert(.highlight) }
        if attributes[.markdownSpan] as? String == "code" { decorations.insert(.code) }
        return decorations
    }

    /// Like `selectedFontTraits`: a mixed selection shows a decoration as off.
    var selectedTextDecorations: MarkdownTextDecoration {
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else { return Self.decorations(in: typingAttributes) }
        var decorations: MarkdownTextDecoration = [.strikethrough, .highlight, .code]
        storage.enumerateAttributes(in: range) { attributes, _, _ in
            decorations.formIntersection(Self.decorations(in: attributes))
        }
        return decorations
    }

    /// A code span holds plain text on one line outside a code block: no math, images or wiki links.
    private func canMakeCode(_ range: NSRange) -> Bool {
        func inCodeBlock(_ attributes: [NSAttributedString.Key: Any]) -> Bool {
            (attributes[.paragraphStyle] as? NSParagraphStyle)?.textBlocks.last is MarkdownCodeBlock
        }
        guard range.length > 0, let storage = textStorage else { return !inCodeBlock(typingAttributes) }
        guard (string as NSString).rangeOfCharacter(from: .newlines, range: range).location == NSNotFound else { return false }
        var allowed = true
        storage.enumerateAttributes(in: range) { attributes, _, stop in
            let span = attributes[.markdownSpan] as? String
            if attributes[.attachment] != nil || (span != nil && span != "code") || inCodeBlock(attributes) {
                allowed = false
                stop.pointee = true
            }
        }
        return allowed
    }

    /// The font unformatted text takes in this paragraph: body, or its heading size.
    private func roleFont(for attributes: [NSAttributedString.Key: Any]) -> NSFont {
        guard let role = attributes[.markdownRole] as? String, role.hasPrefix("h"), let level = Int(role.dropFirst()), (1...6).contains(level),
              let font = document.render(String(repeating: "#", count: level) + " X").attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        else { return document.font }
        return font
    }

    func setTextDecoration(_ decoration: MarkdownTextDecoration, enabled: Bool) {
        let attributes = decorationAttributes(decoration)
        let range = selectedRange()
        if decoration == .code, enabled, !canMakeCode(range) { return }
        guard range.length > 0, let storage = textStorage else {
            if enabled {
                // Code paints its own background, so it replaces a highlight.
                if decoration == .code { typingAttributes.removeValue(forKey: .markdownHighlight) }
                typingAttributes.merge(attributes) { $1 }
            } else if decoration == .code {
                guard typingAttributes[.markdownSpan] as? String == "code" else { return }
                typingAttributes.removeValue(forKey: .markdownSpan)
                typingAttributes.removeValue(forKey: .backgroundColor)
                typingAttributes[.font] = roleFont(for: typingAttributes)
            } else {
                attributes.keys.forEach { typingAttributes.removeValue(forKey: $0) }
            }
            return
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        if enabled {
            if decoration == .code { storage.removeAttribute(.markdownHighlight, range: range) }
            storage.addAttributes(attributes, range: range)
        } else if decoration == .code {
            storage.enumerateAttributes(in: range) { runAttributes, subrange, _ in
                guard runAttributes[.markdownSpan] as? String == "code" else { return }
                storage.removeAttribute(.markdownSpan, range: subrange)
                storage.removeAttribute(.backgroundColor, range: subrange)
                storage.addAttribute(.font, value: roleFont(for: runAttributes), range: subrange)
            }
        } else if decoration == .highlight {
            // Code spans also paint a background; only clear it where the highlight put it.
            storage.enumerateAttribute(.markdownHighlight, in: range) { value, subrange, _ in
                guard value != nil else { return }
                storage.removeAttribute(.markdownHighlight, range: subrange)
                storage.removeAttribute(.backgroundColor, range: subrange)
            }
        } else {
            attributes.keys.forEach { storage.removeAttribute($0, range: range) }
        }
        storage.endEditing()
        didChangeText()
    }

    private var selectedParagraphs: NSAttributedString {
        let range = (string as NSString).paragraphRange(for: selectedRange())
        if range.length > 0, let textStorage { return textStorage.attributedSubstring(from: range) }
        return NSAttributedString(string: "X", attributes: typingAttributes)
    }

    var headingSelection: (level: Int?, canApply: Bool) {
        document.headingSelection(in: selectedParagraphs)
    }

    func setHeadingLevel(_ level: Int) {
        let heading = headingSelection
        guard (0...6).contains(level), heading.canApply, heading.level != level, let storage = textStorage else { return }
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let formatted = document.applyingHeading(level, to: selectedParagraphs)
        guard range.length > 0 else {
            typingAttributes = formatted.attributes(at: 0, effectiveRange: nil)
            return
        }
        breakUndoCoalescing()
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        formatted.enumerateAttributes(in: NSRange(location: 0, length: formatted.length)) { attributes, subrange, _ in
            storage.setAttributes(attributes, range: NSRange(location: range.location + subrange.location, length: subrange.length))
        }
        storage.endEditing()
        didChangeText()
        breakUndoCoalescing()
        if selection.length == 0 {
            typingAttributes = storage.attributes(at: min(selection.location, storage.length - 1), effectiveRange: nil)
        }
    }

    var listSelection: (kind: MarkdownListKind?, containsList: Bool, canApply: Bool) {
        document.listSelection(in: selectedParagraphs)
    }

    /// Choosing the selection's current list style again turns it back into body text, as in Notes.
    func setListKind(_ kind: MarkdownListKind?) {
        let current = listSelection
        let target = kind == current.kind ? nil : kind
        guard current.canApply, target != nil || current.containsList, let storage = textStorage else { return }
        let selection = selectedRange()
        let range = (string as NSString).paragraphRange(for: selection)
        let original = storage.attributedSubstring(from: range)
        let formatted = document.applyingList(target, to: original, typingAttributes: typingAttributes)
        func markerLength(_ text: NSAttributedString) -> Int {
            MarkdownRichText.listMarkerLength(of: (text.string as NSString).paragraphRange(for: NSRange(location: 0, length: 0)), in: text)
        }
        let oldMarker = markerLength(original), newMarker = markerLength(formatted)
        replace(range, with: formatted)
        // Keep the caret or selection on the same text as markers come and go.
        let start = max(selection.location + newMarker - oldMarker, range.location + newMarker)
        let end = selection.length > 0 ? max(start, NSMaxRange(selection) + formatted.length - original.length) : start
        setSelectedRange(NSRange(location: start, length: end - start))
    }

    /// Body clears lists as well as headings.
    func setBodyStyle() {
        if listSelection.containsList { setListKind(nil) }
        setHeadingLevel(0)
    }

    /// Preserve Markdown-only semantics between our editors without replacing AppKit's
    /// RTF/RTFD representations for other apps. The same hooks serve copy and drag.
    private static let markdownPasteboardType = NSPasteboard.PasteboardType("com.typenbash.markdown")

    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownPasteboardType] + super.writablePasteboardTypes
    }

    override var readablePasteboardTypes: [NSPasteboard.PasteboardType] {
        [Self.markdownPasteboardType] + super.readablePasteboardTypes
    }

    override func readSelection(from pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        // NSTextView still supplies this legacy alias on macOS 26, even when
        // the clipboard advertises public.utf8-plain-text.
        guard type == .string || type.rawValue == "NSStringPboardType" || type == Self.markdownPasteboardType else {
            return super.readSelection(from: pboard, type: type)
        }
        guard let source = pboard.string(forType: type) else { return false }
        insertText(document.pastedMarkdown(source, typingAttributes: typingAttributes), replacementRange: selectedRange())
        return true
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard type == .string || type.rawValue == "NSStringPboardType" || type == Self.markdownPasteboardType else {
            return super.writeSelection(to: pboard, type: type)
        }
        guard let storage = textStorage, selectedRange().length > 0 else { return false }
        return pboard.setString(document.markdown(fragment: storage.attributedSubstring(from: selectedRange())), forType: type)
    }
}
