import AppKit
import MarkdownEngine
import MarkdownEngineLatex

extension NSAttributedString.Key {
    /// Index of the source block a run was rendered from.
    static let markdownChunk = NSAttributedString.Key("TypeNBash.markdownChunk")
    /// Paragraph role the font alone can't carry: "h1"…"h6" or "hr".
    static let markdownRole = NSAttributedString.Key("TypeNBash.markdownRole")
    /// Source an atomic run stands for: "code", "wiki:<target>", "source:<raw>", "image:<alt>\u{1F}<url>".
    static let markdownSpan = NSAttributedString.Key("TypeNBash.markdownSpan")
    static let markdownHighlight = NSAttributedString.Key("TypeNBash.markdownHighlight")
}

/// A text block that isn't a table cell otherwise shrinks to its narrowest
/// content, one character per line; these fill the width they sit in.
class MarkdownFullWidthBlock: NSTextBlock {
    override init() {
        super.init()
        setValue(100, type: .percentageValueType, for: .width)
    }
    required init?(coder: NSCoder) { super.init(coder: coder) }
}

final class MarkdownQuoteBlock: MarkdownFullWidthBlock {}
final class MarkdownRuleBlock: MarkdownFullWidthBlock {}

final class MarkdownCodeBlock: MarkdownFullWidthBlock {
    var language = ""
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! MarkdownCodeBlock
        copy.language = language
        return copy
    }
}

final class MarkdownTable: NSTextTable {
    var alignments: [PresentationIntent.TableColumn.Alignment] = []
    override func copy(with zone: NSZone? = nil) -> Any {
        let copy = super.copy(with: zone) as! MarkdownTable
        copy.alignments = alignments
        return copy
    }
}

/// The Formatted view's document: Markdown parsed into rich text, and rich text
/// written back as Markdown. Each top-level block remembers its source and how it
/// rendered, so a block the user hasn't changed is written back byte for byte and
/// only edited blocks are regenerated.
@MainActor final class MarkdownRichText {
    private struct Chunk {
        let body: String
        let trailing: String
        var rendering = NSAttributedString()
    }
    private enum Extra {
        case latex(raw: String, tex: String, display: Bool)
        case wiki(target: String, label: String)
    }

    private var leading = ""
    private var chunks: [Chunk] = []
    /// Chunks touched since load; untouched ones skip the rendering comparison.
    var dirty = IndexSet()
    let baseURL: URL?
    let theme: MarkdownEditorTheme
    let font = NSFont.systemFont(ofSize: 14)
    private static let latex = SwiftMathBridge()

    init(baseURL: URL?, theme: MarkdownEditorTheme) {
        self.baseURL = baseURL
        self.theme = theme
    }

    var codeFont: NSFont { MarkdownEngineCodeHighlighter.shared.codeFont(size: 13) }

    var bodyAttributes: [NSAttributedString.Key: Any] {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = 8
        style.lineHeightMultiple = 1.15
        return [.font: font, .foregroundColor: theme.bodyText, .paragraphStyle: style]
    }

    // MARK: Markdown → rich text

    func load(_ markdown: String) -> NSAttributedString {
        (leading, chunks) = Self.split(markdown)
        dirty = []
        let output = NSMutableAttributedString()
        for index in chunks.indices {
            let start = output.length
            output.append(render(chunks[index].body))
            if index < chunks.count - 1, !output.string.hasSuffix("\n") { output.append(NSAttributedString(string: "\n", attributes: bodyAttributes)) }
            let range = NSRange(location: start, length: output.length - start)
            output.addAttribute(.markdownChunk, value: index, range: range)
            chunks[index].rendering = output.attributedSubstring(from: range)
        }
        return output
    }

    /// Top-level blocks, split at blank lines outside fences. A blank line followed
    /// by an indented line continues the block (list items, loose lists).
    private static func split(_ markdown: String) -> (String, [Chunk]) {
        var lines: [Substring] = []
        markdown.enumerateSubstrings(in: markdown.startIndex..., options: [.byLines, .substringNotRequired]) { _, _, enclosing, _ in
            lines.append(markdown[enclosing])
        }
        var leading = "", chunks: [Chunk] = [], body = "", blanks = "", fence: String?
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                body += line
                if trimmed.hasPrefix(open), trimmed.allSatisfy({ $0 == open.first }) { fence = nil }
                continue
            }
            if trimmed.isEmpty {
                if body.isEmpty && chunks.isEmpty { leading += line } else { blanks += line }
                continue
            }
            if !blanks.isEmpty {
                if let first = line.first, first == " " || first == "\t" {
                    body += blanks
                } else {
                    chunks.append(Chunk(body: body, trailing: blanks))
                    body = ""
                }
                blanks = ""
            }
            body += line
            for marker in ["```", "~~~", "$$"] where trimmed.hasPrefix(marker) {
                let run = marker == "$$" ? "$$" : String(trimmed.prefix { $0 == marker.first })
                if !(marker == "$$" && trimmed.count > 2 && trimmed.hasSuffix("$$")) { fence = run }
            }
        }
        if !body.isEmpty { chunks.append(Chunk(body: body, trailing: blanks)) } else if !blanks.isEmpty { leading += blanks }
        return (leading, chunks)
    }

    func render(_ markdown: String) -> NSAttributedString {
        let trimmed = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("$$"), trimmed.hasSuffix("$$"), trimmed.count > 4 {
            let result = NSMutableAttributedString(attributedString: atomic(.latex(raw: trimmed, tex: String(trimmed.dropFirst(2).dropLast(2)), display: true)))
            result.addAttribute(.paragraphStyle, value: bodyAttributes[.paragraphStyle]!, range: NSRange(location: 0, length: result.length))
            return result
        }
        var extras: [Extra] = []
        let protected = protect(markdown, into: &extras)
        guard let parsed = try? AttributedString(markdown: protected, options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)) else {
            return NSAttributedString(string: markdown, attributes: bodyAttributes)
        }
        let output = build(parsed)
        restore(extras, in: output)
        return output
    }

    /// Hides LaTeX, wiki links and highlight markers from Foundation's parser,
    /// which would otherwise eat their backslash escapes or read them as text.
    private func protect(_ markdown: String, into extras: inout [Extra]) -> String {
        var output = "", fenced = false
        for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            if !output.isEmpty { output += "\n" }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { fenced.toggle() }
            if fenced || trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") { output += line; continue }
            let chars = Array(line)
            var i = 0
            func ahead(_ s: String, at index: Int) -> Bool {
                let probe = Array(s)
                return index + probe.count <= chars.count && Array(chars[index..<index + probe.count]) == probe
            }
            func close(_ s: String, from start: Int) -> Int? {
                var j = start
                while j < chars.count { if chars[j] == "\\" { j += 2; continue }; if ahead(s, at: j) { return j }; j += 1 }
                return nil
            }
            while i < chars.count {
                let c = chars[i]
                if c == "\\", i + 1 < chars.count { output.append(c); output.append(chars[i + 1]); i += 2; continue }
                if c == "`" {
                    var run = 0
                    while i + run < chars.count, chars[i + run] == "`" { run += 1 }
                    let fence = String(repeating: "`", count: run)
                    if let end = close(fence, from: i + run) {
                        output += String(chars[i..<end + run]); i = end + run; continue
                    }
                    output += fence; i += run; continue
                }
                let delimiters: [(String, String)] = [("$$", "$$"), ("$", "$"), ("[[", "]]"), ("==", "==")]
                var matched = false
                for (open, shut) in delimiters where ahead(open, at: i) {
                    let start = i + open.count
                    guard start < chars.count, chars[start] != " ", let end = close(shut, from: start), end > start,
                          open != "$" || (chars[end - 1] != " " && !(end + 1 < chars.count && chars[end + 1].isNumber)) else { continue }
                    let inner = String(chars[start..<end])
                    let raw = open + inner + shut
                    switch open {
                    case "==": output += "\u{E002}" + inner + "\u{E003}"
                    case "[[":
                        let parts = inner.split(separator: "|", maxSplits: 1).map(String.init)
                        extras.append(.wiki(target: parts[0], label: parts.count > 1 ? parts[1] : parts[0]))
                        output += "\u{E000}\(extras.count - 1)\u{E001}"
                    default:
                        extras.append(.latex(raw: raw, tex: inner, display: open == "$$"))
                        output += "\u{E000}\(extras.count - 1)\u{E001}"
                    }
                    i = end + shut.count
                    matched = true
                    break
                }
                if !matched { output.append(c); i += 1 }
            }
        }
        return output
    }

    private func restore(_ extras: [Extra], in output: NSMutableAttributedString) {
        let text = output.string as NSString
        let placeholder = try! NSRegularExpression(pattern: "\u{E000}(\\d+)\u{E001}")
        for match in placeholder.matches(in: output.string, range: NSRange(location: 0, length: text.length)).reversed() {
            guard let index = Int(text.substring(with: match.range(at: 1))), extras.indices.contains(index) else { continue }
            let replacement = NSMutableAttributedString(attributedString: atomic(extras[index]))
            let attributes = output.attributes(at: match.range.location, effectiveRange: nil)
            replacement.addAttribute(.paragraphStyle, value: attributes[.paragraphStyle] ?? NSParagraphStyle.default,
                                     range: NSRange(location: 0, length: replacement.length))
            if let chunk = attributes[.markdownChunk] { replacement.addAttribute(.markdownChunk, value: chunk, range: NSRange(location: 0, length: replacement.length)) }
            output.replaceCharacters(in: match.range, with: replacement)
        }
        let highlight = try! NSRegularExpression(pattern: "\u{E002}([^\u{E003}]*)\u{E003}")
        for match in highlight.matches(in: output.string, range: NSRange(location: 0, length: output.length)).reversed() {
            let inner = match.range(at: 1)
            output.addAttributes([.markdownHighlight: true, .backgroundColor: theme.highlightColor], range: inner)
            output.deleteCharacters(in: NSRange(location: NSMaxRange(inner), length: 1))
            output.deleteCharacters(in: NSRange(location: match.range.location, length: 1))
        }
        let citation = try! NSRegularExpression(pattern: "\\[@[^\\]\\n]+\\]")
        for match in citation.matches(in: output.string, range: NSRange(location: 0, length: output.length)) {
            output.addAttribute(.foregroundColor, value: theme.link, range: match.range)
        }
    }

    private func atomic(_ extra: Extra) -> NSAttributedString {
        switch extra {
        case let .wiki(target, label):
            return NSAttributedString(string: label, attributes: bodyAttributes.merging([
                .foregroundColor: theme.link, .markdownSpan: "wiki:" + target]) { $1 })
        case let .latex(raw, tex, display):
            guard let result = Self.latex.render(latex: tex, mode: display ? .display : .inline, fontSize: font.pointSize, theme: theme) else {
                return NSAttributedString(string: raw, attributes: bodyAttributes.merging([.markdownSpan: "source:" + raw]) { $1 })
            }
            let attachment = NSTextAttachment()
            attachment.image = result.image
            attachment.bounds = CGRect(x: 0, y: -result.baselineOffset, width: result.size.width, height: result.size.height)
            let string = NSMutableAttributedString(attachment: attachment)
            string.addAttributes(bodyAttributes.merging([.markdownSpan: "source:" + raw]) { $1 }, range: NSRange(location: 0, length: 1))
            return string
        }
    }

    /// Foundation's runs carry block structure as presentation intents; each
    /// distinct paragraph-level intent becomes one text paragraph.
    private func build(_ parsed: AttributedString) -> NSMutableAttributedString {
        let output = NSMutableAttributedString()
        var lastParagraph: Int?
        var lists: [Int: NSTextList] = [:], quotes: [Int: MarkdownQuoteBlock] = [:]
        var tables: [Int: MarkdownTable] = [:], cells: [Int: NSTextTableBlock] = [:]
        var codeBlocks: [Int: MarkdownCodeBlock] = [:]
        var markedItems: Set<Int> = [], numberedLists: Set<ObjectIdentifier> = []
        // The cell to fill next: Foundation leaves empty cells out, but a table needs them all.
        var tableCursor: (table: MarkdownTable, row: Int, column: Int)?
        var needsTerminator = false

        func terminate() {
            guard needsTerminator, output.length > 0 else { return }
            output.append(NSAttributedString(string: "\n", attributes: output.attributes(at: output.length - 1, effectiveRange: nil)))
            needsTerminator = false
        }
        func pad(_ table: MarkdownTable, row: Int, from: Int, to: Int) {
            guard from < to else { return }
            terminate()
            for column in from..<to {
                output.append(NSAttributedString(string: "\n", attributes: cellAttributes(table, row: row, column: column)))
            }
        }

        for run in parsed.runs {
            var text = String(parsed[run.range].characters)
            let components = run.presentationIntent?.components ?? []
            guard let paragraph = components.first(where: {
                switch $0.kind { case .paragraph, .header, .codeBlock, .thematicBreak, .tableCell: true; default: false }
            }) else { continue }
            var attributes = bodyAttributes
            let style = (attributes[.paragraphStyle] as! NSParagraphStyle).mutableCopy() as! NSMutableParagraphStyle
            var blocks: [NSTextBlock] = []
            var textLists: [NSTextList] = []
            var listItem: (identity: Int, ordinal: Int)?
            var table: MarkdownTable?, row = 0
            var cell: (row: Int, column: Int)?
            var codeColors: NSAttributedString?
            for component in components.reversed() {
                switch component.kind {
                case .blockQuote:
                    let block = quotes[component.identity] ?? {
                        let block = MarkdownQuoteBlock()
                        block.setWidth(3, type: .absoluteValueType, for: .border, edge: .minX)
                        block.setBorderColor(theme.mutedText.withAlphaComponent(0.5), for: .minX)
                        block.setWidth(12, type: .absoluteValueType, for: .padding, edge: .minX)
                        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                        quotes[component.identity] = block
                        return block
                    }()
                    blocks.append(block)
                    attributes[.foregroundColor] = theme.mutedText
                case .orderedList, .unorderedList:
                    let ordered: Bool = { if case .orderedList = component.kind { return true }; return false }()
                    let list = lists[component.identity]
                        ?? NSTextList(markerFormat: ordered ? NSTextList.MarkerFormat("{decimal}.") : (textLists.isEmpty ? .disc : .circle), options: 0)
                    lists[component.identity] = list
                    textLists.append(list)
                case .listItem(let ordinal):
                    listItem = (component.identity, ordinal)
                    if let list = textLists.last, list.isOrdered,
                       numberedLists.insert(ObjectIdentifier(list)).inserted {
                        list.startingItemNumber = ordinal
                    }
                case .table(let columns):
                    let value = tables[component.identity] ?? {
                        let value = MarkdownTable()
                        value.numberOfColumns = columns.count
                        value.alignments = columns.map(\.alignment)
                        value.collapsesBorders = true
                        value.hidesEmptyCells = false
                        tables[component.identity] = value
                        return value
                    }()
                    table = value
                case .tableHeaderRow:
                    row = 0
                    attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
                case .tableRow(let index):
                    row = index
                case .tableCell(let column):
                    guard let table else { break }
                    cell = (row, column)
                    let block = cells[component.identity] ?? cellBlock(table, row: row, column: column)
                    cells[component.identity] = block
                    blocks.append(block)
                    style.alignment = Self.alignment(table.alignments, column)
                    style.paragraphSpacing = 0
                case .header(let level):
                    attributes[.font] = NSFont.systemFont(ofSize: [26, 22, 18, 16, 14, 13][min(level, 6) - 1], weight: .bold)
                    attributes[.markdownRole] = "h\(level)"
                    style.paragraphSpacingBefore = level <= 2 ? 10 : 6
                case .codeBlock(let language):
                    let block = codeBlocks[component.identity] ?? {
                        let block = MarkdownCodeBlock()
                        block.language = language ?? ""
                        block.backgroundColor = MarkdownEngineCodeHighlighter.shared.backgroundColor()
                        block.setWidth(10, type: .absoluteValueType, for: .padding)
                        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .minY)
                        block.setWidth(4, type: .absoluteValueType, for: .margin, edge: .maxY)
                        codeBlocks[component.identity] = block
                        return block
                    }()
                    blocks.append(block)
                    attributes[.font] = codeFont
                    style.paragraphSpacing = 0
                    style.lineHeightMultiple = 1
                    if text.hasSuffix("\n") { text.removeLast() }
                    codeColors = MarkdownEngineCodeHighlighter.shared.highlight(code: text, language: language)
                case .thematicBreak:
                    let block = MarkdownRuleBlock()
                    block.setWidth(1, type: .absoluteValueType, for: .border, edge: .maxY)
                    block.setBorderColor(theme.mutedText.withAlphaComponent(0.4), for: .maxY)
                    block.setWidth(6, type: .absoluteValueType, for: .margin, edge: .minY)
                    blocks.append(block)
                    attributes[.markdownRole] = "hr"
                    attributes[.font] = NSFont.systemFont(ofSize: 4)
                    text = "\u{00A0}"
                default: break
                }
            }
            style.textBlocks = blocks
            if !textLists.isEmpty {
                let indent = CGFloat(textLists.count) * 24
                style.textLists = textLists
                style.headIndent = indent
                style.firstLineHeadIndent = indent - 24
                style.tabStops = [NSTextTab(textAlignment: .right, location: indent - 6), NSTextTab(textAlignment: .left, location: indent)]
                style.paragraphSpacing = 3
            }
            attributes[.paragraphStyle] = style

            if paragraph.identity != lastParagraph {
                lastParagraph = paragraph.identity
                if let table, let cell {
                    if let cursor = tableCursor, cursor.table === table {
                        if cursor.row != cell.row {
                            pad(table, row: cursor.row, from: cursor.column, to: table.numberOfColumns)
                            pad(table, row: cell.row, from: 0, to: cell.column)
                        } else {
                            pad(table, row: cell.row, from: cursor.column, to: cell.column)
                        }
                    } else {
                        if let cursor = tableCursor { pad(cursor.table, row: cursor.row, from: cursor.column, to: cursor.table.numberOfColumns) }
                        pad(table, row: cell.row, from: 0, to: cell.column)
                    }
                    tableCursor = (table, cell.row, cell.column + 1)
                } else if let cursor = tableCursor {
                    pad(cursor.table, row: cursor.row, from: cursor.column, to: cursor.table.numberOfColumns)
                    tableCursor = nil
                }
                terminate()
                if let item = listItem, let list = textLists.last, markedItems.insert(item.identity).inserted {
                    output.append(NSAttributedString(string: "\t" + list.marker(forItemNumber: item.ordinal) + "\t", attributes: attributes))
                }
            }
            if let inline = run.inlinePresentationIntent {
                var traits: NSFontTraitMask = []
                if inline.contains(.stronglyEmphasized) { traits.insert(.boldFontMask) }
                if inline.contains(.emphasized) { traits.insert(.italicFontMask) }
                if !traits.isEmpty { attributes[.font] = NSFontManager.shared.convert(attributes[.font] as! NSFont, toHaveTrait: traits) }
                if inline.contains(.strikethrough) {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = theme.strikethroughColor
                }
                if inline.contains(.code) {
                    attributes[.font] = codeFont
                    attributes[.backgroundColor] = MarkdownEngineCodeHighlighter.shared.backgroundColor()
                    attributes[.markdownSpan] = "code"
                }
                if inline.contains(.softBreak) { text = " " }
                if inline.contains(.lineBreak) { text = "\u{2028}" }
            }
            if let link = run.link { attributes[.link] = link }
            needsTerminator = true
            if let url = run.imageURL {
                attributes[.markdownSpan] = "image:" + text + "\u{1F}" + url.relativeString
                if let resolved = URL(string: url.relativeString, relativeTo: baseURL), resolved.isFileURL,
                   let image = NSImage(contentsOf: resolved) {
                    let attachment = NSTextAttachment()
                    let scale = min(1, 560 / max(image.size.width, 1))
                    attachment.image = image
                    attachment.bounds = CGRect(origin: .zero, size: CGSize(width: image.size.width * scale, height: image.size.height * scale))
                    let string = NSMutableAttributedString(attachment: attachment)
                    string.addAttributes(attributes, range: NSRange(location: 0, length: string.length))
                    output.append(string)
                    continue
                }
                attributes[.foregroundColor] = theme.link
            }
            let start = output.length
            output.append(NSAttributedString(string: text, attributes: attributes))
            if let codeColors {
                codeColors.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: min(codeColors.length, (text as NSString).length))) { color, range, _ in
                    if let color { output.addAttribute(.foregroundColor, value: color, range: NSRange(location: start + range.location, length: range.length)) }
                }
            }
        }
        if let cursor = tableCursor { pad(cursor.table, row: cursor.row, from: cursor.column, to: cursor.table.numberOfColumns) }
        return output
    }

    func cellBlock(_ table: MarkdownTable, row: Int, column: Int) -> NSTextTableBlock {
        let block = NSTextTableBlock(table: table, startingRow: row, rowSpan: 1, startingColumn: column, columnSpan: 1)
        block.setWidth(1, type: .absoluteValueType, for: .border)
        block.setBorderColor(theme.mutedText.withAlphaComponent(0.35))
        block.setWidth(6, type: .absoluteValueType, for: .padding)
        if row == 0 { block.backgroundColor = theme.mutedText.withAlphaComponent(0.08) }
        return block
    }

    /// Attributes for a cell's paragraph; an empty cell is just its terminator.
    func cellAttributes(_ table: MarkdownTable, row: Int, column: Int) -> [NSAttributedString.Key: Any] {
        var attributes = bodyAttributes
        let style = NSMutableParagraphStyle()
        style.textBlocks = [cellBlock(table, row: row, column: column)]
        style.alignment = Self.alignment(table.alignments, column)
        attributes[.paragraphStyle] = style
        if row == 0 { attributes[.font] = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        return attributes
    }

    private static func alignment(_ alignments: [PresentationIntent.TableColumn.Alignment], _ column: Int) -> NSTextAlignment {
        guard alignments.indices.contains(column) else { return .natural }
        switch alignments[column] {
        case .center: return .center
        case .right: return .right
        default: return .natural
        }
    }
}

// MARK: Rich text → Markdown

extension MarkdownRichText {
    /// The document's Markdown: untouched blocks from their source, the rest regenerated.
    func markdown(from text: NSAttributedString) -> String {
        var output = leading
        var emitted = IndexSet()
        let paragraphs = Self.paragraphs(in: text)
        var index = 0
        while index < paragraphs.count {
            let chunk = Self.chunk(of: paragraphs[index], in: text)
            var end = index + 1
            while end < paragraphs.count, Self.chunk(of: paragraphs[end], in: text) == chunk { end += 1 }
            let range = NSRange(location: paragraphs[index].location,
                                length: NSMaxRange(paragraphs[end - 1]) - paragraphs[index].location)
            if let chunk, chunks.indices.contains(chunk), !emitted.contains(chunk) {
                emitted.insert(chunk)
                let original = chunks[chunk]
                if !dirty.contains(chunk) || text.attributedSubstring(from: range).isEqual(to: original.rendering) {
                    output += original.body + original.trailing
                } else {
                    let regenerated = blocks(in: text, paragraphs: Array(paragraphs[index..<end]))
                    if !regenerated.isEmpty {
                        output += regenerated + (original.body.hasSuffix("\n") || !original.trailing.isEmpty ? "\n" : "") + original.trailing
                    }
                }
            } else {
                let regenerated = blocks(in: text, paragraphs: Array(paragraphs[index..<end]))
                if !regenerated.isEmpty { output += regenerated + (end < paragraphs.count ? "\n\n" : "\n") }
            }
            index = end
        }
        return output
    }

    /// Markdown for a copied selection, all regenerated.
    func markdown(fragment text: NSAttributedString) -> String {
        blocks(in: text, paragraphs: Self.paragraphs(in: text))
    }

    private static func paragraphs(in text: NSAttributedString) -> [NSRange] {
        let string = text.string as NSString
        var ranges: [NSRange] = []
        var location = 0
        while location < string.length {
            let range = string.paragraphRange(for: NSRange(location: location, length: 0))
            ranges.append(range)
            location = NSMaxRange(range)
        }
        return ranges
    }

    private static func chunk(of paragraph: NSRange, in text: NSAttributedString) -> Int? {
        text.attribute(.markdownChunk, at: paragraph.location, effectiveRange: nil) as? Int
    }

    /// One unit per code block, table or other paragraph, joined the way Markdown expects.
    private func blocks(in text: NSAttributedString, paragraphs: [NSRange]) -> String {
        struct Unit { var lines: [String]; let quote: Int; var list: NSTextList? = nil }
        var units: [Unit] = []
        var counters: [ObjectIdentifier: Int] = [:]
        var index = 0
        while index < paragraphs.count {
            let range = paragraphs[index]
            let style = text.attribute(.paragraphStyle, at: range.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
            let quote = style.textBlocks.filter { $0 is MarkdownQuoteBlock }.count
            if let code = style.textBlocks.last as? MarkdownCodeBlock {
                var lines: [String] = []
                while index < paragraphs.count, Self.style(of: paragraphs[index], in: text).textBlocks.last === code {
                    lines.append(Self.content(of: paragraphs[index], in: text))
                    index += 1
                }
                let fence = lines.contains { $0.contains("```") } ? "````" : "```"
                units.append(Unit(lines: [fence + code.language] + lines + [fence], quote: quote))
                continue
            }
            if let cell = style.textBlocks.last as? NSTextTableBlock, let table = cell.table as? MarkdownTable {
                var grid: [[String]] = []
                while index < paragraphs.count, let block = Self.style(of: paragraphs[index], in: text).textBlocks.last as? NSTextTableBlock,
                      block.table === table {
                    while grid.count <= block.startingRow { grid.append(Array(repeating: "", count: table.numberOfColumns)) }
                    if block.startingColumn < table.numberOfColumns {
                        let value = inline(text, Self.contentRange(of: paragraphs[index], in: text)).replacingOccurrences(of: "|", with: "\\|")
                        let current = grid[block.startingRow][block.startingColumn]
                        grid[block.startingRow][block.startingColumn] = current.isEmpty ? value : current + "<br>" + value
                    }
                    index += 1
                }
                let separator = (0..<table.numberOfColumns).map { column -> String in
                    switch table.alignments.indices.contains(column) ? table.alignments[column] : .left {
                    case .center: ":---:"
                    case .right: "---:"
                    default: "---"
                    }
                }
                var lines = grid.map { "| " + $0.joined(separator: " | ") + " |" }
                lines.insert("| " + separator.joined(separator: " | ") + " |", at: min(1, lines.count))
                units.append(Unit(lines: lines, quote: quote))
                continue
            }
            index += 1
            let contentRange = Self.contentRange(of: range, in: text)
            let role = text.attribute(.markdownRole, at: range.location, effectiveRange: nil) as? String
            if role == "hr" { units.append(Unit(lines: ["---"], quote: quote)); continue }
            var body = inline(text, contentRange)
            if let list = style.textLists.last {
                let indent = style.textLists.dropLast().map { $0.isOrdered ? "   " : "  " }.joined()
                if (text.string as NSString).substring(with: range).hasPrefix("\t") {
                    let number = counters[ObjectIdentifier(list), default: list.startingItemNumber]
                    counters[ObjectIdentifier(list)] = number + 1
                    let marker = list.isOrdered ? "\(number). " : "- "
                    units.append(Unit(lines: [indent + marker + body], quote: quote, list: style.textLists.first))
                } else if !body.isEmpty {
                    let continuation = indent + (list.isOrdered ? "   " : "  ")
                    units.append(Unit(lines: body.components(separatedBy: "\n").map { continuation + $0 }, quote: quote))
                }
                continue
            }
            guard !body.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            if let role, role.hasPrefix("h"), let level = Int(role.dropFirst()) {
                units.append(Unit(lines: [String(repeating: "#", count: level) + " " + body], quote: quote))
                continue
            }
            if let match = body.range(of: #"^(#{1,6}\s|>|[-+]\s|\d+[.)]\s)"#, options: .regularExpression) {
                let digits = body[match].prefix { $0.isNumber }
                body = digits.isEmpty ? "\\" + body : digits + "\\" + body.dropFirst(digits.count)
            }
            units.append(Unit(lines: body.components(separatedBy: "\n"), quote: quote))
        }
        var output = ""
        for (offset, unit) in units.enumerated() {
            let prefix = String(repeating: "> ", count: unit.quote)
            if offset > 0 {
                let previous = units[offset - 1]
                if let list = unit.list, list === previous.list, unit.quote == previous.quote {
                    output += "\n"
                } else {
                    let shared = min(unit.quote, previous.quote)
                    output += "\n" + String(String(repeating: "> ", count: shared).dropLast()) + "\n"
                }
            }
            output += unit.lines.map { (prefix + $0).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression) }.joined(separator: "\n")
        }
        return output
    }

    private static func style(of paragraph: NSRange, in text: NSAttributedString) -> NSParagraphStyle {
        text.attribute(.paragraphStyle, at: paragraph.location, effectiveRange: nil) as? NSParagraphStyle ?? .default
    }

    /// The paragraph without its terminator and, for a list item, its marker.
    private static func contentRange(of paragraph: NSRange, in text: NSAttributedString) -> NSRange {
        let string = text.string as NSString
        var range = paragraph
        while range.length > 0, [0x0A, 0x0D, 0x2029].contains(string.character(at: NSMaxRange(range) - 1)) { range.length -= 1 }
        if style(of: paragraph, in: text).textLists.isEmpty == false, range.length > 0, string.character(at: range.location) == 0x09 {
            let second = string.range(of: "\t", range: NSRange(location: range.location + 1, length: range.length - 1))
            if second.location != NSNotFound { range = NSRange(location: NSMaxRange(second), length: NSMaxRange(range) - NSMaxRange(second)) }
        }
        return range
    }

    private static func content(of paragraph: NSRange, in text: NSAttributedString) -> String {
        (text.string as NSString).substring(with: contentRange(of: paragraph, in: text))
    }

    private enum Mark: String, CaseIterable { case highlight = "==", strike = "~~", bold = "**", italic = "*" }

    /// Inline Markdown for a run of text. Markers hug their text: surrounding
    /// spaces move outside them, as CommonMark requires.
    private func inline(_ text: NSAttributedString, _ range: NSRange) -> String {
        var output = "", open: [Mark] = [], pending = ""
        func apply(_ desired: [Mark]) {
            if let first = open.firstIndex(where: { !desired.contains($0) }) {
                output += open[first...].reversed().map(\.rawValue).joined()
                open.removeSubrange(first...)
            }
            output += pending
            pending = ""
            for mark in desired where !open.contains(mark) { output += mark.rawValue; open.append(mark) }
        }
        var location = range.location
        while location < NSMaxRange(range) {
            var effective = NSRange()
            let attributes = text.attributes(at: location, longestEffectiveRange: &effective, in: NSRange(location: location, length: NSMaxRange(range) - location))
            let piece = (text.string as NSString).substring(with: effective)
            location = NSMaxRange(effective)
            var desired: [Mark] = []
            if attributes[.markdownHighlight] != nil { desired.append(.highlight) }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { desired.append(.strike) }
            // Headings and header cells are bold by role, not by emphasis.
            if let font = attributes[.font] as? NSFont, attributes[.markdownSpan] as? String != "code" {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.boldFontMask), attributes[.markdownRole] == nil, !isHeaderCell(effective, in: text) { desired.append(.bold) }
                if traits.contains(.italicFontMask) { desired.append(.italic) }
            }
            if let link = attributes[.link] {
                let url = (link as? URL)?.absoluteString ?? "\(link)"
                var linkRange = NSRange()
                _ = text.attribute(.link, at: effective.location, longestEffectiveRange: &linkRange, in: NSRange(location: effective.location, length: NSMaxRange(range) - effective.location))
                let plain = NSMutableAttributedString(attributedString: text.attributedSubstring(from: linkRange))
                plain.removeAttribute(.link, range: NSRange(location: 0, length: plain.length))
                apply([])
                output += "[" + inline(plain, NSRange(location: 0, length: plain.length)) + "](" + url + ")"
                location = NSMaxRange(linkRange)
                continue
            }
            if let span = attributes[.markdownSpan] as? String {
                apply(desired)
                if span == "code" {
                    let fence = piece.contains("`") ? "``" : "`"
                    output += fence + (fence.count > 1 ? " \(piece) " : piece) + fence
                } else if span.hasPrefix("wiki:") {
                    let target = String(span.dropFirst(5))
                    output += "[[" + (piece == target ? target : target + "|" + piece) + "]]"
                } else if span.hasPrefix("source:") {
                    output += span.dropFirst(7)
                } else if span.hasPrefix("image:") {
                    let parts = span.dropFirst(6).split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
                    let alt = piece == "\u{FFFC}" ? String(parts[0]) : piece
                    output += "![" + alt + "](" + (parts.count > 1 ? String(parts[1]) : "") + ")"
                } else {
                    output += Self.escape(piece)
                }
                continue
            }
            let core = piece.trimmingCharacters(in: .whitespaces)
            guard !core.isEmpty else { pending += piece; continue }
            let lead = piece.prefix { $0 == " " || $0 == "\t" }
            let trail = piece.reversed().prefix { $0 == " " || $0 == "\t" }
            pending += lead
            apply(desired)
            output += Self.escape(core).replacingOccurrences(of: "\u{2028}", with: "\\\n")
            pending = String(trail)
        }
        apply([])
        return output.replacingOccurrences(of: "\u{FFFC}", with: "")
    }

    private func isHeaderCell(_ range: NSRange, in text: NSAttributedString) -> Bool {
        (Self.style(of: range, in: text).textBlocks.last as? NSTextTableBlock)?.startingRow == 0
    }

    /// Escapes only what could read as syntax, so `5 * 3` and `snake_case` stay as typed.
    private static func escape(_ text: String) -> String {
        var output = ""
        let characters = Array(text)
        let pairsDollars = characters.filter { $0 == "$" }.count > 1
        func touches(_ index: Int) -> (before: Bool, after: Bool) {
            (index > 0 && !characters[index - 1].isWhitespace, index + 1 < characters.count && !characters[index + 1].isWhitespace)
        }
        func intraword(_ index: Int) -> Bool {
            index > 0 && index + 1 < characters.count && characters[index - 1].isLetterOrDigit && characters[index + 1].isLetterOrDigit
        }
        for (index, character) in characters.enumerated() {
            let (before, after) = touches(index)
            switch character {
            case "`": output += "\\`"
            case "\\" where index + 1 == characters.count
                || (characters[index + 1].isASCII && (characters[index + 1].isPunctuation || characters[index + 1].isSymbol)):
                output += "\\\\"
            case "*" where before || after: output += "\\*"
            case "_" where (before || after) && !intraword(index): output += "\\_"
            case "$" where pairsDollars && (before || after): output += "\\$"
            case "~" where index + 1 < characters.count && characters[index + 1] == "~": output += "\\~"
            case "=" where index + 1 < characters.count && characters[index + 1] == "=": output += "\\="
            default: output.append(character)
            }
        }
        return output
    }
}

private extension NSTextList {
    var isOrdered: Bool { markerFormat.rawValue.contains("decimal") }
}

private extension Character {
    var isLetterOrDigit: Bool { isLetter || isNumber }
}
