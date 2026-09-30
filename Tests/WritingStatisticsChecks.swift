import Foundation
@testable import TypeNBash

@main
struct WritingStatisticsChecks {
    @MainActor static func main() async throws {
        let empty = WritingStatistics(text: " \r\n\t", markdown: false)
        precondition(empty.words == 0 && empty.paragraphs == 0 && empty.sentences == 0 && empty.pages == 0)
        let prose = WritingStatistics(text: "Hello world.\r\nAnother sentence!\r\n \r\nLast paragraph", markdown: false)
        precondition(prose.words == 6 && prose.paragraphs == 2 && prose.sentences == 3 && prose.pages == 1)
        let markdown = WritingStatistics(text: "# Hello world\n\nA **bold** [link](https://example.com/many/hidden/words).\n\n- First item\n- Second item", markdown: true)
        precondition(markdown.words == 9 && markdown.paragraphs == 4 && markdown.sentences == 4)
        let inline = WritingStatistics(text: "A **bold** and *italic* sentence.", markdown: true)
        precondition(inline.words == 5 && inline.paragraphs == 1 && inline.sentences == 1)
        for (wordCount, pages) in [(1, 1), (250, 1), (251, 2), (500, 2)] {
            precondition(WritingStatistics(text: Array(repeating: "word", count: wordCount).joined(separator: " "), markdown: false).pages == pages)
        }
        let unicode = WritingStatistics(text: "Café déjà vu. 你好世界。", markdown: false)
        precondition(unicode.words >= 4 && unicode.sentences == 2)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let model = FileBrowserModel()
        for ext in ["md", "TXT", "tex", "swift", "wrtx"] {
            let url = root.appendingPathComponent("sample.\(ext)")
            try "Original words.".write(to: url, atomically: true, encoding: .utf8)
            model.select(WorkspaceFileEntry(url: url, isDirectory: false, byteCount: 15))
            precondition(model.writingText == nil, "Old text must clear while the new file loads")
            for _ in 0..<200 {
                if case .none = model.preview { try await Task.sleep(for: .milliseconds(10)) }
                else { break }
            }
            let supported = ["md", "TXT"].contains(ext)
            precondition((model.writingText != nil) == supported)
            if supported {
                model.updatePreviewText("Unsaved replacement has four words.")
                precondition(model.writingText == "Unsaved replacement has four words.")
                precondition(WritingStatistics(text: model.writingText!, markdown: ext == "md").words == 5)
            }
        }
        let file = root.appendingPathComponent("sample.TXT")
        model.select(WorkspaceFileEntry(url: file, isDirectory: false, byteCount: 15))
        for _ in 0..<200 {
            if model.writingText != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let monitor = WritingStatisticsMonitor()
        let sampling = Task { await monitor.sample(model: model, file: file) }
        for _ in 0..<200 {
            if monitor.statistics != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(monitor.statistics?.words == 2, "Opening a document counts immediately")
        model.updatePreviewText("Now there are five words.")
        try await Task.sleep(for: .milliseconds(300))
        precondition(monitor.statistics?.words == 2, "Typing retains the previous counts")
        // Keep editing through the next tick: continuous typing must not defer it.
        for index in 0..<70 {
            model.updatePreviewText("Now there are five words" + (index.isMultiple(of: 2) ? "." : "!"))
            if monitor.statistics?.words == 5 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        precondition(monitor.statistics?.words == 5, "A five-second tick samples ongoing edits")
        sampling.cancel()
        await sampling.value
        model.updatePreviewText("Stopped.")
        precondition(monitor.statistics?.words == 5, "Cancellation ends the sampling loop")
        print("Writing statistics checks passed, including silent periodic refresh during continuous edits and cancellation.")
    }
}
