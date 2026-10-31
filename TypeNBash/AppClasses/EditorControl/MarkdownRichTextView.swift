import AppKit
import MarkdownEngine

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
                    replacement.enumerateAttribute(.font, in: all) { font, range, _ in
                        guard let font = font as? NSFont else { return }
                        replacement.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: style == .bold ? .boldFontMask : .italicFontMask), range: range)
                    }
                case .strike:
                    replacement.addAttributes([.strikethroughStyle: NSUnderlineStyle.single.rawValue, .strikethroughColor: document.theme.strikethroughColor], range: all)
                case .highlight:
                    replacement.addAttributes([.markdownHighlight: true, .backgroundColor: document.theme.highlightColor], range: all)
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
        let here = (text.paragraphRange(for: selectedRange()))
        func cell(at paragraph: NSRange) -> NSTextTableBlock? {
            guard paragraph.location < storage.length else { return nil }
            return (storage.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle)?.textBlocks.last as? NSTextTableBlock
        }
        guard let current = cell(at: here), let table = current.table as? MarkdownTable else { return false }
        var paragraph = here
        while true {
            let next = forward ? NSMaxRange(paragraph) : paragraph.location - 1
            guard next >= 0, next < storage.length else { break }
            paragraph = text.paragraphRange(for: NSRange(location: next, length: 0))
            guard let block = cell(at: paragraph), block.table === table else { break }
            if block !== current {
                var content = paragraph
                if content.length > 0, text.character(at: NSMaxRange(content) - 1) == 0x0A { content.length -= 1 }
                setSelectedRange(content)
                return true
            }
        }
        guard forward else { return true }
        // Past the last cell: a new empty row after it.
        let rowEnd = NSMaxRange(here)
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
        case "b": toggle(.boldFontMask); return true
        case "i": toggle(.italicFontMask); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    private func toggle(_ trait: NSFontTraitMask) {
        let manager = NSFontManager.shared
        let range = selectedRange()
        guard range.length > 0, let storage = textStorage else {
            if let font = typingAttributes[.font] as? NSFont {
                typingAttributes[.font] = manager.traits(of: font).contains(trait)
                    ? manager.convert(font, toNotHaveTrait: trait) : manager.convert(font, toHaveTrait: trait)
            }
            return
        }
        var adds = false
        storage.enumerateAttribute(.font, in: range) { font, _, stop in
            if let font = font as? NSFont, !manager.traits(of: font).contains(trait) { adds = true; stop.pointee = true }
        }
        guard shouldChangeText(in: range, replacementString: nil) else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range) { font, subrange, _ in
            guard let font = font as? NSFont else { return }
            storage.addAttribute(.font, value: adds ? manager.convert(font, toHaveTrait: trait) : manager.convert(font, toNotHaveTrait: trait), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    /// Pasted Markdown arrives formatted; a single line takes the paragraph's own style.
    override func paste(_ sender: Any?) {
        guard let string = NSPasteboard.general.string(forType: .string) else { return super.paste(sender) }
        let pasted = string.contains("\n")
            ? document.render(string)
            : NSAttributedString(string: string, attributes: typingAttributes)
        insertText(pasted, replacementRange: selectedRange())
    }

    /// Rich text for Notes and Mail, Markdown for everything that takes plain text.
    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard super.writeSelection(to: pboard, types: types) else { return false }
        if types.contains(.string), let storage = textStorage, selectedRange().length > 0 {
            pboard.setString(document.markdown(fragment: storage.attributedSubstring(from: selectedRange())), forType: .string)
        }
        return true
    }
}

/// Lets TextFinder batch its highlight updates, as the code editor's layout manager does.
final class MarkdownRichLayoutManager: NSLayoutManager, ValidationIgnorable {
    var ignoresDisplayValidation = false

    override func invalidateDisplay(forCharacterRange charRange: NSRange) {
        guard !ignoresDisplayValidation else { return }
        super.invalidateDisplay(forCharacterRange: charRange)
    }
}
