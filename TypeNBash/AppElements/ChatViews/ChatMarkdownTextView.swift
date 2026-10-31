import Foundation
import SwiftUI
import Textual

/// Presents chat Markdown with Textual's `StructuredText`, which walks the full
/// block tree Foundation's parser produces (nested lists, quotes holding lists
/// or code, tables, list start numbers) instead of flattening it to root blocks.
public struct MarkdownTextView: View {
    // Textual sizes headings and code relative to the environment font, so
    // setting `.body` here keeps markdown on the active AppTypeface and in step
    // with surrounding chat text rather than on hard-coded system fonts.
    private let source: String
    private let foreground: Color
    private let accent: Color

    public init(_ source: String, foreground: Color, accent: Color) {
        self.source = source
        self.foreground = foreground
        self.accent = accent
    }

    public var body: some View {
        // StructuredText re-parses only when `source` changes, so a streaming
        // reply parses once per token and not on every unrelated body update.
        StructuredText(markdown: source, syntaxExtensions: [.math])
            .font(.body)
            .foregroundStyle(foreground)
            .tint(accent)
            .textual.textSelection(.enabled)
    }
}
