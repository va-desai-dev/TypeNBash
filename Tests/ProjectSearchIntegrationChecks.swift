import AppKit
import SwiftUI
import TextFind
@testable import TypeNBash

@main struct ProjectSearchIntegrationChecks {
    @MainActor static func main() {
        setbuf(stdout, nil)
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run() } catch { fatalError("Project search: \(error)") }
            exit(0)
        }
        NSApp.run()
    }

    @MainActor static func run() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-search-\(UUID())")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/example.swift")
        let markdown = root.appendingPathComponent("Notes.md")
        let other = root.appendingPathComponent("other.txt")
        let original = "😀 first\r\nlet café = 42\r\nlet café = 43\r\n"
        try Data(original.utf8).write(to: file)
        try Data("# café\ncafé notes\n".utf8).write(to: markdown)
        try Data("café saved\n".utf8).write(to: other)
        try Data([0, 1, 2]).write(to: root.appendingPathComponent("binary"))
        try Data(repeating: 65, count: ProjectSearchEngine.byteLimit + 1).write(to: root.appendingPathComponent("large.txt"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try Data("café excluded".utf8).write(to: root.appendingPathComponent("node_modules/dependency.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("loop"), withDestinationURL: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("outside"), withDestinationURL: root.deletingLastPathComponent())

        let suite = "ProjectSearch-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ProjectStore(defaults: defaults)
        let session = WindowSession(localRoot: root)
        await session.open(store.makeProject(directoryPath: root.path), at: .local(root))
        defer { session.close() }
        let editor = EditorSession()
        let model = ProjectSearchModel(session: session, editor: editor)
        var options = FindOptions(defaults: defaults)
        options.regularExpression = false
        options.ignoresCase = false
        options.wholeWord = false
        model.options = options
        model.query = "café"
        try await finished(model)
        precondition(model.count == 5 && model.results.count == 3)
        precondition(model.skipped == 2, "Oversized and binary files must be reported")
        precondition(!model.limited)
        check("recursive root search, excluded dependencies, binary/size limits, symlink loops")

        model.pathFilter = "SOURCES"
        precondition(!model.isSearching, "The path filter must not search again")
        precondition(model.results.count == 3 && model.visibleResults.map(\.path) == ["Sources/example.swift"])
        precondition(model.count == 2, "The count follows the path filter")
        model.pathFilter = "other"
        model.previewReplacement()
        try await readyReview(model)
        precondition(model.review!.replacements.map(\.file.path) == ["other.txt"],
                     "Replace All must leave files the filter hides alone")
        model.review = nil
        model.pathFilter = ""
        precondition(model.count == 5 && model.visibleResults.count == 3)
        check("footer path filter narrows results, count and Replace All without searching again")

        session.fileBrowser.tree.navigate(to: root.appendingPathComponent("Sources"))
        model.schedule()
        try await finished(model)
        precondition(model.results.count == 3, "Browsing into a child must not narrow the search root")
        model.includes = "Sources/**/*.swift"
        try await finished(model)
        precondition(model.count == 2 && model.results.count == 1)
        precondition(model.results[0].matches.map(\.line) == [2, 3])
        check("include globs, CRLF line numbers, root independent of browser directory")

        let result = model.results[0]
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            ProjectSearchView(model: model, onOpen: { _, _ in }, files: session.fileBrowser).frame(width: 300)
            WorkspacePane(model: session.fileBrowser, session: editor).frame(width: 700)
        }.frame(height: 650))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 1000, height: 650),
            styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        let opened = await model.open(result, match: result.matches[1])
        precondition(opened)
        try await Task.sleep(for: .milliseconds(400))
        precondition(editor.textView?.selectedString == "café")
        precondition(editor.textView?.selectedRange() == result.matches[1].range)
        precondition(session.fileBrowser.savedPreviewText == original)
        check("result opening waits for the source editor and selects exact UTF-16 range")

        window.makeFirstResponder(editor.textView)
        model.showsReplacement = true
        try await Task.sleep(for: .milliseconds(150))
        precondition(window.firstResponder === editor.textView, "Mounting replacement controls must not take editor focus")
        model.showsReplacement = false
        model.reveal()
        NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(for: .milliseconds(400))
        guard let queryEditor = window.firstResponder as? NSTextView, queryEditor !== editor.textView else {
            fatalError("Project search did not focus the shared find field")
        }
        queryEditor.setSelectedRange(NSRange(location: 0, length: queryEditor.string.utf16.count))
        queryEditor.insertText("café", replacementRange: queryEditor.selectedRange())
        try await Task.sleep(for: .milliseconds(100))
        precondition(model.query == "café" && editor.textView?.string == original)
        check("project find focuses the shared input and typing leaves the document unchanged")
        try await finished(model)

        let unchangedQuery = model.query
        model.query = unchangedQuery
        precondition(!model.isSearching, "Unchanged field commits must not invalidate results")
        model.replacement = "tea"
        try await finished(model)
        model.previewReplacement(file: result, match: result.matches[0].range)
        try await readyReview(model)
        precondition(model.review!.count == 1)
        await model.apply(model.review!)
        try await finished(model)
        precondition(session.fileBrowser.hasUnsavedChanges)
        precondition(session.fileBrowser.searchText!.contains("let tea = 42"))
        precondition(try! String(contentsOf: file, encoding: .utf8) == original)
        precondition(editor.textView?.undoManager?.canUndo == true)
        editor.textView?.undoManager?.undo()
        try await Task.sleep(for: .milliseconds(100))
        precondition(editor.textView?.string == original)
        check("single-match replacement preserves dirty buffers, saved disk contents, and native Undo")

        session.fileBrowser.updatePreviewText(original + "café draft\n")
        model.includes = ""
        try await finished(model)
        precondition(model.count == 6)
        let otherResult = model.results.first { $0.url == other }!
        let blocked = await model.open(otherResult, match: otherResult.matches[0])
        precondition(!blocked && session.fileBrowser.selectedFile == file)
        check("unsaved buffer is searched and result navigation cannot discard it")

        model.previewReplacement(file: otherResult)
        try await readyReview(model)
        try Data("external edit".utf8).write(to: other)
        await model.apply(model.review!)
        precondition(try! String(contentsOf: other, encoding: .utf8) == "external edit")
        precondition(model.message?.contains("changed") == true)
        try await finished(model)
        let md = model.results.first { $0.url == markdown }!
        model.previewReplacement(file: md)
        try await readyReview(model)
        await model.apply(model.review!)
        precondition(try! String(contentsOf: markdown, encoding: .utf8) == "# tea\ntea notes\n")
        try await finished(model)
        check("changed files are skipped and closed-file replacements are saved")

        options.regularExpression = true
        let regex = try await ProjectSearchEngine.search(text: original, url: file, path: "example.swift",
            query: #"let (café) = (\d+)"#, options: options, limit: 100)
        let replacement = try await ProjectSearchEngine.replacement(for: regex, match: nil, with: "$2: $1")
        precondition(replacement.text == "😀 first\r\n42: café\r\n43: café\r\n")
        let zero = try await ProjectSearchEngine.search(text: "ab", url: file, path: "x", query: "(?=b)", options: options, limit: 10)
        let zeroReplacement = try await ProjectSearchEngine.replacement(for: zero, match: nil, with: "X")
        precondition(zeroReplacement.text == "aXb")
        options.regularExpression = false
        options.ignoresDiacritics = true
        options.ignoresCase = true
        options.wholeWord = true
        let words = try await ProjectSearchEngine.search(text: "CAFÉ cafeteria café", url: file, path: "x", query: "cafe", options: options, limit: 10)
        precondition(words.matches.count == 2)
        let capped = try await ProjectSearchEngine.search(text: "aaaaaa", url: file, path: "x", query: "a", options: model.options, limit: 2)
        precondition(capped.matches.count == 2)
        check("shared regex/capture replacement, zero-width matches, diacritics, case, whole words, match cap")

        model.options.regularExpression = true
        model.query = "["
        try await finished(model)
        precondition(model.message != nil && model.results.isEmpty)
        model.options.regularExpression = false
        model.query = "should be cancelled"
        model.query = "café"
        try await finished(model)
        precondition(model.count == 3)
        model.query = "tea"
        model.cancel()
        try await Task.sleep(for: .milliseconds(350))
        precondition(!model.isSearching && model.results.isEmpty && !model.canReplace)
        check("invalid regex, rapid-query cancellation, and incomplete-search replacement guard")

        let fs = LocalWorkspaceFileSystem()
        do {
            _ = try await fs.readSearchFile(at: root.appendingPathComponent("outside/escape.txt"), root: root, limit: 100)
            fatalError("Escaping symlink was accepted")
        } catch { }
        do {
            _ = try await fs.readSearchFile(at: root.appendingPathComponent("large.txt"), root: root, limit: 100)
            fatalError("Truncated search read was accepted")
        } catch { }
        model.query = "café"
        try await finished(model)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/centcom-project-search.png"))
        }
        let csv = root.appendingPathComponent("table.csv")
        let rawCSV = "\"name\",\"value\"\r\n\"café\",\"1\"\r\n"
        try Data(rawCSV.utf8).write(to: csv)
        session.fileBrowser.select(WorkspaceFileEntry(url: csv, isDirectory: false, byteCount: rawCSV.utf8.count))
        for _ in 0..<50 {
            if case .table = session.fileBrowser.preview { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        precondition(session.fileBrowser.searchText == rawCSV && !session.fileBrowser.hasUnsavedChanges)
        model.schedule()
        try await finished(model)
        let csvResult = model.results.first { $0.url == csv }!
        let openedCSV = await model.open(csvResult, match: csvResult.matches[0])
        precondition(openedCSV && !session.fileBrowser.hasUnsavedChanges)
        precondition(session.fileBrowser.savedPreviewText == rawCSV)
        try await Task.sleep(for: .milliseconds(400))
        precondition(editor.textView?.selectedString == "café")
        check("CSV source navigation preserves original quoting, line endings, and clean state")
        session.closeProject()
        model.reset()
        model.reveal()
        model.query = "café"
        try await Task.sleep(for: .milliseconds(350))
        precondition(!model.showsSearch && !model.isSearching && model.results.isEmpty)
        check("filesystem boundary enforcement and project-only lifecycle")
        print("All project search integration checks passed")
    }

    @MainActor static func finished(_ model: ProjectSearchModel) async throws {
        for _ in 0..<100 {
            if !model.isSearching { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        fatalError("Search timed out")
    }

    @MainActor static func readyReview(_ model: ProjectSearchModel) async throws {
        for _ in 0..<100 {
            if !model.isReplacing { precondition(model.review != nil, model.message ?? "Missing review"); return }
            try await Task.sleep(for: .milliseconds(30))
        }
        fatalError("Replacement preview timed out")
    }

    static func check(_ message: String) { print("PASS: \(message)") }
}
