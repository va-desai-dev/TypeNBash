import AppKit
import Combine
import BibTeXViewer
import BibTeXKit

extension NSAttributedString.Key {
    static let citationColor = NSAttributedString.Key("TypeNBash.citationColor")
}

nonisolated struct EditorCitationMatch: Equatable, Sendable {
    let range: NSRange
    let matched: Bool

    static func find(in text: String, keys: Set<String>) -> [Self] {
        let source = text as NSString
        let whole = NSRange(location: 0, length: source.length)
        var excluded: [NSRange] = []
        var fence: (marker: Character, count: Int, start: Int)?
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: .byLines) { line, _, enclosing, _ in
            let line = line ?? ""
            let range = NSRange(enclosing, in: text)
            let trimmed = line.drop(while: { $0 == " " })
            let indent = line.count - trimmed.count
            let marker = trimmed.first
            let count = trimmed.prefix(while: { $0 == marker }).count
            if let open = fence {
                if indent <= 3, marker == open.marker, count >= open.count,
                   trimmed.dropFirst(count).trimmingCharacters(in: .whitespaces).isEmpty {
                    excluded.append(NSRange(location: open.start, length: NSMaxRange(range) - open.start))
                    fence = nil
                }
            } else if indent <= 3, (marker == "`" || marker == "~"), count >= 3 {
                fence = (marker!, count, range.location)
            } else if indent >= 4 || line.hasPrefix("\t") {
                excluded.append(range)
            }
        }
        if let fence { excluded.append(NSRange(location: fence.start, length: source.length - fence.start)) }
        let code = try! NSRegularExpression(pattern: #"(`+)[\s\S]*?\1(?!`)"#)
        excluded += code.matches(in: text, range: whole).map(\.range)
        let brackets = try! NSRegularExpression(pattern: #"(?<!\\)\[[^\[\]\r\n]*\]"#)
        let citation = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_\\])(?:-)?@([\p{L}\p{N}_][\p{L}\p{N}_:.#$%&+?<>~/\-]*)"#)
        return brackets.matches(in: text, range: whole).compactMap { bracket in
            guard !excluded.contains(where: { NSIntersectionRange($0, bracket.range).length > 0 }) else { return nil }
            let end = NSMaxRange(bracket.range)
            if end < source.length, [40, 91].contains(Int(source.character(at: end))) { return nil }
            let references = citation.matches(in: text, range: bracket.range)
            guard !references.isEmpty else { return nil }
            return Self(range: bracket.range, matched: references.allSatisfy {
                keys.contains(source.substring(with: $0.range(at: 1)))
            })
        }
    }
}

/// Owns only temporary display attributes; never edits text, undo or syntax colors.
@MainActor final class EditorCitationHighlighter {
    private weak var textView: NSTextView?
    private weak var library: BibLibrary?
    private var subscription: AnyCancellable?
    private var task: Task<Void, Never>?
    private var keys: Set<String>?
    private var previousText: String?
    private var previousKeys: Set<String>?

    func configure(textView: NSTextView, library: BibLibrary?, fileURL: URL?) {
        let library = fileURL?.pathExtension.lowercased() == "md" ? library : nil
        guard let library else {
            if self.textView != nil { stop(); self.textView = nil }
            return
        }
        if self.textView !== textView || self.library !== library {
            stop()
            self.textView = textView
            self.library = library
            subscription = library.$document.sink { [weak self] document in
                self?.keys = document?.keys
                self?.refresh()
            }
        }
        refresh()
    }

    func refresh() {
        guard let textView else { return }
        let text = textView.string
        guard text != previousText || keys != previousKeys else { return }
        previousText = text
        previousKeys = keys
        task?.cancel()
        clear()
        guard let keys else { return }
        task = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
            let matches = await Task.detached(priority: .utility) {
                EditorCitationMatch.find(in: text, keys: keys)
            }.value
            guard !Task.isCancelled, let self, let view = self.textView,
                  view.string == text, self.keys == keys, let layout = view.layoutManager else { return }
            for match in matches {
                layout.addTemporaryAttribute(.citationColor,
                    value: match.matched ? NSColor.systemGreen : NSColor.systemRed,
                    forCharacterRange: match.range)
            }
            layout.invalidateDisplay(forCharacterRange: NSRange(location: 0, length: (text as NSString).length))
        }
    }

    func stop() {
        task?.cancel()
        subscription = nil
        clear()
        library = nil
        keys = nil
        previousText = nil
        previousKeys = nil
    }

    private func clear() {
        guard let view = textView, let layout = view.layoutManager else { return }
        let range = NSRange(location: 0, length: (view.string as NSString).length)
        layout.removeTemporaryAttribute(.citationColor, forCharacterRange: range)
        layout.invalidateDisplay(forCharacterRange: range)
    }
}
