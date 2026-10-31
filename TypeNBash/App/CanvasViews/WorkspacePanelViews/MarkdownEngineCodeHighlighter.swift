//
//  MarkdownEngineCodeHighlighter.swift
//  TypeNBash
//
//  Colors the Markdown editor's fenced code with the code editor's own
//  parsers and palette, so a ```swift block reads exactly like a .swift file.
//

import AppKit
import MarkdownEngine
import SwiftUI
import SyntaxFormat
import SyntaxParsers
import ValueRange

/// The engine asks for a block's colors synchronously, but our parsers are
/// actors. An unparsed block comes up plain, and once its parse lands every
/// engine view is told to restyle, which then finds it in the cache.
///
/// The engine only calls in on the main thread, which `assumeIsolated` checks.
nonisolated final class MarkdownEngineCodeHighlighter: SyntaxHighlighter, @unchecked Sendable {
    static let shared = MarkdownEngineCodeHighlighter()

    /// Every engine view restyles on this: a slow parse landed or the palette changed.
    static let didChange = Notification.Name("TypeNBash.MarkdownEngineCodeHighlighter.didChange")

    /// Highlights by syntax name and code. Colors are looked up on each call,
    /// so a palette change needs no new parse.
    private let cache = NSCache<NSString, Parsed>()
    /// One parser per syntax name; nil when the syntax has none.
    @MainActor private var parsers: [String: (any HighlightParsing)?] = [:]
    @MainActor private var isRestylePending = false
    /// Keys whose parse is running, so a restyle before it lands doesn't start another.
    @MainActor private var inFlight: Set<NSString> = []
    /// Latest parses per syntax name, oldest first, as UTF-16 to match `NSRange`.
    @MainActor private var recentParses: [String: [(code: [UInt16], highlights: [Highlight])]] = [:]
    private static let recentParseLimit = 16

    private init() {
        cache.countLimit = 256
    }

    // MARK: SyntaxHighlighter

    var appearanceDidChangeNotification: Notification.Name? { Self.didChange }

    func codeFont(size: CGFloat) -> NSFont {
        // NSFont isn't Sendable either; see `highlight(code:language:)`.
        var font: NSFont?
        MainActor.assumeIsolated {
            font = NSFont(descriptor: CodeEditorTextView.editorFont.fontDescriptor, size: size)
        }
        return font ?? .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    func backgroundColor() -> NSColor {
        MainActor.assumeIsolated { Self.palette().blockBackground }
    }

    func highlight(code: String, language: String?) -> NSAttributedString? {
        // `assumeIsolated` only returns Sendable values, and NSAttributedString
        // isn't one, so the string leaves through a local instead.
        var result: NSAttributedString?
        MainActor.assumeIsolated {
            guard let name = SyntaxDefinition.syntaxName(forFenceLanguage: language) else { return }
            let key = "\(name)\u{0}\(code)" as NSString
            let highlights: [Highlight]
            if let cached = cache.object(forKey: key)?.highlights {
                highlights = cached
            } else {
                parse(code, syntaxName: name, key: key)
                // Without this an edited block flashes plain on every keystroke.
                guard let provisional = provisionalHighlights(for: code, syntaxName: name) else { return }
                highlights = provisional
            }
            result = colorize(code, highlights)
        }
        return result
    }

    // MARK: Palette

    /// Restyles every engine view, for when the code editor's colors change.
    @MainActor func paletteDidChange() {
        requestRestyle()
    }

    /// The code editor's colors for the current appearance, and the fill
    /// behind a block: the editor's background, or the card where that is
    /// clear, nudged toward the text so the block stands apart from the page.
    @MainActor private static func palette() -> (theme: Theme, blockBackground: NSColor) {
        let appearance = NSApp.effectiveAppearance
        let theme = AppTheme.shared.editorTheme(appearance.isDark ? .dark : .light)
        // The palette's defaults follow the appearance; blend them as this one.
        var fill = NSColor.clear
        appearance.performAsCurrentDrawingAppearance {
            let background = theme.background.color.alphaComponent > 0
                ? theme.background.color
                : NSColor(AppTheme.shared.card)
            fill = background.blended(withFraction: 0.06, of: theme.text.color) ?? background
        }
        return (theme, fill)
    }

    @MainActor private func colorize(_ code: String, _ highlights: [Highlight]) -> NSAttributedString {
        let theme = Self.palette().theme
        let string = NSMutableAttributedString(string: code, attributes: [.foregroundColor: theme.text.color])
        for highlight in highlights {
            if let color = theme.style(for: highlight.value)?.color {
                string.addAttribute(.foregroundColor, value: color, range: highlight.range)
            }
        }
        return string
    }

    // MARK: Parsing

    /// Starts parsing `code`; the result is cached and announced when it lands.
    ///
    /// Never waits on the parse: blocking the main thread on a semaphore that a
    /// lower-QoS task signals is a priority inversion, and the parsers are
    /// actors with no synchronous path.
    @MainActor private func parse(_ code: String, syntaxName name: String, key: NSString) {
        guard let parser = parser(named: name), !inFlight.contains(key) else { return }
        inFlight.insert(key)

        Task(priority: .userInitiated) { @MainActor [cache] in
            let range = NSRange(location: 0, length: (code as NSString).length)
            let highlights = (try? await parser.parseHighlights(in: code, range: range))?.highlights ?? []
            cache.setObject(Parsed(highlights), forKey: key)
            self.inFlight.remove(key)
            self.remember(code, highlights, syntaxName: name)
            self.requestRestyle()
        }
    }

    /// Keeps the latest parses per syntax so an edited block has a base to adjust.
    @MainActor private func remember(_ code: String, _ highlights: [Highlight], syntaxName name: String) {
        var entries = recentParses[name, default: []]
        entries.append((Array(code.utf16), highlights))
        if entries.count > Self.recentParseLimit { entries.removeFirst(entries.count - Self.recentParseLimit) }
        recentParses[name] = entries
    }

    /// Stand-in colors while `code` reparses: the recent parse sharing the most
    /// prefix and suffix with it (the same block before the edit), with ranges
    /// after the edit shifted and ranges spanning it stretched. Nil when no
    /// recent parse resembles `code`.
    @MainActor private func provisionalHighlights(for code: String, syntaxName name: String) -> [Highlight]? {
        guard let entries = recentParses[name], !entries.isEmpty else { return nil }
        let new = Array(code.utf16)

        var best: (highlights: [Highlight], prefix: Int, oldEditEnd: Int, delta: Int)?
        var bestScore = 0
        for (old, highlights) in entries.reversed() {
            let limit = min(old.count, new.count)
            var prefix = 0
            while prefix < limit, old[prefix] == new[prefix] { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix, old[old.count - 1 - suffix] == new[new.count - 1 - suffix] { suffix += 1 }
            let score = prefix + suffix
            if score > bestScore {
                bestScore = score
                best = (highlights, prefix, old.count - suffix, new.count - old.count)
            }
        }
        // Mostly-different code is another block; borrowing its colors is worse than none.
        guard let best, bestScore * 2 >= new.count else { return nil }

        return best.highlights.compactMap { highlight in
            var range = highlight.range
            if range.upperBound <= best.prefix {
                // Before the edit: unchanged.
            } else if range.location >= best.oldEditEnd {
                range.location += best.delta
            } else if range.location <= best.prefix, range.upperBound >= best.oldEditEnd {
                range.length += best.delta
            } else {
                return nil
            }
            guard range.length > 0, range.location >= 0, range.upperBound <= new.count else { return nil }
            return Highlight(value: highlight.value, range: range)
        }
    }

    /// The same parser the code editor would pick: tree-sitter where the
    /// syntax has a highlight query, its regex definition otherwise.
    @MainActor private func parser(named name: String) -> (any HighlightParsing)? {
        if let cached = parsers[name] { return cached }
        let parser: (any HighlightParsing)? =
            if let syntax = TreeSitterSyntax(name: name), syntax.features.contains(.highlight),
               let client = try? LanguageRegistry.shared.parser(syntax: syntax) {
                client
            } else {
                SyntaxDefinition.load(name: name)?.syntax.highlightParser
            }
        parsers[name] = parser
        return parser
    }

    /// Several late parses in one run loop pass share one restyle.
    @MainActor private func requestRestyle() {
        guard !isRestylePending else { return }
        isRestylePending = true
        DispatchQueue.main.async {
            self.isRestylePending = false
            NotificationCenter.default.post(name: Self.didChange, object: nil)
        }
    }
}

/// A cached parse; `NSCache` takes only objects.
private nonisolated final class Parsed: Sendable {
    let highlights: [Highlight]
    init(_ highlights: [Highlight]) { self.highlights = highlights }
}
