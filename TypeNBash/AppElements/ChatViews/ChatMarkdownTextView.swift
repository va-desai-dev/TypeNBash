import Foundation
import SwiftUI

/// Presents Foundation's native Markdown value with SwiftUI typography and
/// layout. `Text` renders the inline attributes; this view only lays out the
/// block presentation intents that Foundation already attached.
public struct MarkdownTextView: View {
    // Route every block through the app's type roles instead of raw system fonts,
    // so markdown inherits the active AppTypeface (design + per-role weights) and
    // matches surrounding chat text. Hard-coding .body/.largeTitle here bypassed
    // the token system and rendered in a different face/kerning than the app.
    private let document: MarkdownDocument
    private let foreground: Color
    private let accent: Color

    public init(_ source: String, foreground: Color, accent: Color) {
        self.document = MarkdownDocument(MarkdownText.render(source))
        self.foreground = foreground
        self.accent = accent
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(document.blocks) { block in
                blockView(block)
            }
        }
        .foregroundStyle(foreground)
        .tint(accent)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block.kind {
        case .paragraph(let text):
            Text(text)
                .font(.body)
                .bold(false)
                .fontWeight(.light)
                .fontWidth(.standard)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)

        case .blockQuote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(accent.opacity(0.7))
                    .frame(width: 3)
                Text(text)
                    .font(.subheadline)
                    .italic(true)
                    .foregroundStyle(foreground.opacity(0.82))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 7) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(ordered ? "\(index + 1)." : "•")
                            .font(.body.weight(.semibold))
                            .foregroundStyle(accent)
                            .frame(minWidth: 18, alignment: .trailing)
                        Text(item)
                            .font(.body)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

        case .codeBlock(let language, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let language, !language.isEmpty {
                    Text(language.uppercased())
                        .font(.body.monospaced())
                        .monospaced(true)
                        .foregroundStyle(foreground.opacity(0.55))
                        .padding(.horizontal, 12)
                        .padding(.top, 9)
                }
                ScrollView(.horizontal) {
                    Text(code)
                        .font(.body.monospaced())
                        .monospaced(true)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(12)
                }
            }
            .background(foreground.opacity(0.065), in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(foreground.opacity(0.12), lineWidth: 0.75)
            }

        case .thematicBreak:
            Divider()
                .overlay(foreground.opacity(0.24))
                .padding(.vertical, 3)

        case .table(let table):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(Array(table.rows.enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(0..<table.columns.count, id: \.self) { column in
                                tableCell(
                                    row.cells[column] ?? AttributedString(),
                                    isHeader: row.isHeader,
                                    alignment: table.columns[column].alignment
                                )
                            }
                        }
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(foreground.opacity(0.16), lineWidth: 0.75)
                }
            }
        }
    }

    private func tableCell(
        _ text: AttributedString,
        isHeader: Bool,
        alignment: PresentationIntent.TableColumn.Alignment
    ) -> some View {
        Text(text)
            .font(isHeader ? .subheadline.weight(.bold) : .body)
            .frame(
                minWidth: 96,
                maxWidth: 260,
                alignment: frameAlignment(alignment)
            )
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(isHeader ? foreground.opacity(0.075) : .clear)
            .overlay {
                Rectangle().stroke(foreground.opacity(0.12), lineWidth: 0.5)
            }
    }

    // Map heading levels onto the app's type roles (which already carry the active
    // face's design and the app's per-role weights), so a markdown H1/H2 matches an
    // app title exactly instead of an ad-hoc system font + hand-set weight.
    private func headingFont(_ level: Int) -> Font {
        switch level {
            case 1: .largeTitle
            case 2: .title
            case 3: .title2
            case 4: .headline
            case 5: .subheadline
            default: .body.weight(.semibold)
        }
    }

    private func frameAlignment(
        _ alignment: PresentationIntent.TableColumn.Alignment
    ) -> Alignment {
        switch alignment {
        case .left: .leading
        case .center: .center
        case .right: .trailing
        @unknown default: .leading
        }
    }
}

private struct MarkdownDocument {
    let blocks: [MarkdownBlock]

    init(_ parsed: AttributedString) {
        var groups: [MarkdownRootGroup] = []
        for run in parsed.runs {
            let components = run.presentationIntent?.components ?? []
            let root = components.last
            let rootID = root?.identity ?? -(groups.count + 1)
            let rootKind = root?.kind ?? .paragraph
            var text = AttributedString(parsed[run.range])
            text.presentationIntent = nil
            let piece = MarkdownPiece(text: text, components: components)

            if groups.last?.id == rootID {
                groups[groups.count - 1].pieces.append(piece)
            } else {
                groups.append(
                    MarkdownRootGroup(id: rootID, rootKind: rootKind, pieces: [piece])
                )
            }
        }

        blocks = groups.map(\.block)
    }
}

private struct MarkdownRootGroup {
    let id: Int
    let rootKind: PresentationIntent.Kind
    var pieces: [MarkdownPiece]

    var block: MarkdownBlock {
        switch rootKind {
        case .header(let level):
            MarkdownBlock(id: id, kind: .heading(level: level, joinedText))
        case .blockQuote:
            MarkdownBlock(id: id, kind: .blockQuote(joinedText))
        case .orderedList:
            MarkdownBlock(id: id, kind: .list(ordered: true, items: listItems))
        case .unorderedList:
            MarkdownBlock(id: id, kind: .list(ordered: false, items: listItems))
        case .codeBlock(let language):
            MarkdownBlock(id: id, kind: .codeBlock(language: language, joinedText))
        case .thematicBreak:
            MarkdownBlock(id: id, kind: .thematicBreak)
        case .table(let columns):
            MarkdownBlock(id: id, kind: .table(table(columns: columns)))
        default:
            MarkdownBlock(id: id, kind: .paragraph(joinedText))
        }
    }

    private var joinedText: AttributedString {
        pieces.reduce(into: AttributedString()) { $0.append($1.text) }
    }

    private var listItems: [AttributedString] {
        var items: [(id: Int, text: AttributedString)] = []
        for piece in pieces {
            guard let item = piece.components.first(where: {
                if case .listItem = $0.kind { true } else { false }
            }) else { continue }
            if items.last?.id == item.identity {
                items[items.count - 1].text.append(piece.text)
            } else {
                items.append((item.identity, piece.text))
            }
        }
        return items.map(\.text)
    }

    private func table(
        columns: [PresentationIntent.TableColumn]
    ) -> MarkdownTable {
        var rows: [(id: Int, row: MarkdownTableRow)] = []

        for piece in pieces {
            guard let rowIntent = piece.components.first(where: {
                switch $0.kind {
                case .tableHeaderRow, .tableRow: true
                default: false
                }
            }),
            let cellIntent = piece.components.first(where: {
                if case .tableCell = $0.kind { true } else { false }
            }),
            case .tableCell(let column) = cellIntent.kind else { continue }

            let isHeader: Bool
            if case .tableHeaderRow = rowIntent.kind { isHeader = true }
            else { isHeader = false }

            if rows.last?.id != rowIntent.identity {
                rows.append((rowIntent.identity, MarkdownTableRow(isHeader: isHeader)))
            }
            rows[rows.count - 1].row.cells[column, default: AttributedString()]
                .append(piece.text)
        }

        return MarkdownTable(columns: columns, rows: rows.map(\.row))
    }
}

private struct MarkdownPiece {
    let text: AttributedString
    let components: [PresentationIntent.IntentType]
}

private struct MarkdownBlock: Identifiable {
    enum Kind {
        case paragraph(AttributedString)
        case heading(level: Int, AttributedString)
        case blockQuote(AttributedString)
        case list(ordered: Bool, items: [AttributedString])
        case codeBlock(language: String?, AttributedString)
        case thematicBreak
        case table(MarkdownTable)
    }

    let id: Int
    let kind: Kind
}

private struct MarkdownTable {
    let columns: [PresentationIntent.TableColumn]
    let rows: [MarkdownTableRow]
}

private struct MarkdownTableRow {
    let isHeader: Bool
    var cells: [Int: AttributedString] = [:]
}
