import Foundation
import NaturalLanguage
import Observation

/// Counts readable blocks, including headings, list items and code in Markdown.
/// Pages are a manuscript estimate, independent of the editor's window size.
nonisolated struct WritingStatistics: Equatable, Sendable {
    let words: Int
    let paragraphs: Int
    let sentences: Int
    var pages: Int { (words + 249) / 250 }

    init(text: String, markdown: Bool) {
        var readable = text
        if markdown, let document = try? AttributedString(markdown: text) {
            readable = ""
            var previousBlock: Int?
            for run in document.runs {
                let block = run.presentationIntent?.components.first?.identity
                if block != previousBlock, !readable.isEmpty { readable += "\n\n" }
                readable += String(document[run.range].characters)
                previousBlock = block
            }
        }

        // Soft line breaks belong to the same paragraph; blank lines separate them.
        var blocks: [String] = []
        var paragraph = ""
        readable.enumerateLines { line, _ in
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                if !paragraph.isEmpty { blocks.append(paragraph); paragraph = "" }
            } else {
                if !paragraph.isEmpty { paragraph += " " }
                paragraph += line
            }
        }
        if !paragraph.isEmpty { blocks.append(paragraph) }

        let wordTokenizer = NLTokenizer(unit: .word)
        let sentenceTokenizer = NLTokenizer(unit: .sentence)
        var words = 0
        var sentences = 0
        for block in blocks {
            wordTokenizer.string = block
            wordTokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { _, _ in
                words += 1
                return true
            }
            sentenceTokenizer.string = block
            sentenceTokenizer.enumerateTokens(in: block.startIndex..<block.endIndex) { range, _ in
                // Punctuation-only blocks aren't sentences.
                if block[range].unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) {
                    sentences += 1
                }
                return true
            }
        }
        self.words = words
        self.paragraphs = blocks.count
        self.sentences = sentences
    }
}

/// One sampling loop per mounted document; edits don't restart it or clear counts.
@MainActor @Observable
final class WritingStatisticsMonitor {
    private(set) var statistics: WritingStatistics?
    private(set) var file: URL?

    func sample(model: FileBrowserModel, file: URL) async {
        self.file = file
        statistics = nil
        var previousText: String?
        while !Task.isCancelled, model.selectedFile == file {
            if let text = model.writingText, text != previousText {
                let markdown = file.pathExtension.lowercased() == "md"
                let result = await Task.detached(priority: .utility) {
                    WritingStatistics(text: text, markdown: markdown)
                }.value
                guard !Task.isCancelled, model.selectedFile == file else { return }
                statistics = result
                previousText = text
            }
            do { try await Task.sleep(for: .seconds(1)) }
            catch { return }
        }
    }
}

extension FileBrowserModel {
    var writingText: String? {
        guard let selectedFile, WindowSession.textFileTypes(for: selectedFile) else { return nil }
        switch preview {
        case .text(let text), .markdown(let text): return text
        default: return nil
        }
    }
}
