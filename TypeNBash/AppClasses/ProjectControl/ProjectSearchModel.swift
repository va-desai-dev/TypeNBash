import Foundation
import AppKit
import Observation
import TextFind

@MainActor @Observable final class ProjectSearchModel {
    let session: WindowSession
    let editor: EditorSession
    var query = "" { didSet { if !query.utf8.elementsEqual(oldValue.utf8) { schedule() } } }
    var replacement = ""
    var options = FindOptions() {
        didSet {
            guard options != oldValue else { return }
            // Persist the case choice so it survives relaunch and matches the editor's find bar.
            if options.ignoresCase != oldValue.ignoresCase {
                UserDefaults.standard[.findIgnoresCase] = options.ignoresCase
            }
            schedule()
        }
    }
    var includes = "" { didSet { if includes != oldValue { schedule() } } }
    var excludes = ".git, .build, node_modules, DerivedData" { didSet { if excludes != oldValue { schedule() } } }
    /// The sidebar footer's filter: narrows the results shown, counted and
    /// replaced to files whose project path contains it, ignoring case.
    /// Unlike `includes`, it never re-runs the search.
    var pathFilter = ""
    var showsSearch = false
    var showsReplacement = false
    private(set) var focusRequest = 0
    private(set) var results: [ProjectSearchResult] = []
    private(set) var isSearching = false
    private(set) var isReplacing = false
    private(set) var scanned = 0
    private(set) var skipped = 0
    private(set) var limited = false
    var message: String?
    var review: ProjectReplacementReview?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var bufferWasEdited = false
    private var generation = 0
    private var navigationGeneration = 0

    init(session: WindowSession, editor: EditorSession) {
        self.session = session
        self.editor = editor
    }

    var visibleResults: [ProjectSearchResult] {
        let filter = pathFilter.trimmingCharacters(in: .whitespaces)
        guard !filter.isEmpty else { return results }
        return results.filter { $0.path.localizedCaseInsensitiveContains(filter) }
    }
    var count: Int { visibleResults.reduce(0) { $0 + $1.matches.count } }
    var canReplace: Bool { !isSearching && !isReplacing && !limited && count > 0 }

    func reveal() {
        guard session.mode == .project else { return }
        showsSearch = true
        focusRequest += 1
    }

    func cancel() {
        task?.cancel()
        generation += 1
        if isSearching { limited = true }
        isSearching = false
    }

    func reset() {
        cancel()
        navigationGeneration += 1
        results = []
        review = nil
        message = nil
        pathFilter = ""
        showsSearch = false
    }

    /// The open document is searched from memory, so only an edit can change the
    /// results. Loading a file — from the tree or a search result — leaves the
    /// buffer equal to disk and must not restart the search. Reverting or
    /// leaving an edited buffer does, since results were taken from the edit.
    func bufferDidChange() {
        let edited = session.fileBrowser.hasUnsavedChanges
        defer { bufferWasEdited = edited }
        if edited || bufferWasEdited { schedule() }
    }

    func schedule() {
        guard !isReplacing else { return }
        cancel()
        results = []
        review = nil
        scanned = 0
        skipped = 0
        limited = false
        message = nil
        guard session.mode == .project, !query.isEmpty else { return }
        let request = generation
        let backendGeneration = session.terminalGeneration
        let search = ProjectSearchRequest(root: session.rootDirectory, fileSystem: session.fileSystem,
            query: query, options: options, includes: includes, excludes: excludes,
            bufferURL: session.fileBrowser.selectedFile,
            buffer: session.fileBrowser.isPreviewTruncated ? nil : session.fileBrowser.searchText)
        isSearching = true
        task = Task {
            do {
                try await Task.sleep(for: .milliseconds(250))
                let reachedLimit = try await ProjectSearchEngine.crawl(search,
                    isCurrent: { request == generation && session.terminalGeneration == backendGeneration }) { event in
                    switch event {
                    case .scanned: scanned += 1
                    case .skipped: skipped += 1
                    case .found(let result): results.append(result)
                    }
                }
                if reachedLimit { limited = true }
                isSearching = false
            } catch is CancellationError { }
            catch {
                guard request == generation else { return }
                isSearching = false
                message = error.localizedDescription
            }
        }
    }

    func open(_ result: ProjectSearchResult, match: ProjectSearchMatch) async -> Bool {
        navigationGeneration += 1
        let navigation = navigationGeneration
        let browser = session.fileBrowser
        guard !isReplacing, session.mode == .project, !browser.isSaving else { return false }
        if editor.hasPendingCSVEdit || (browser.hasUnsavedChanges && browser.selectedFile != result.url) {
            message = "Save the current document before opening a result in another file."
            return false
        }
        let root = session.rootDirectory, backendGeneration = session.terminalGeneration
        let selectedFile = browser.selectedFile, currentText = browser.searchText
        do {
            let text: String
            if browser.selectedFile == result.url, !browser.isPreviewTruncated, let buffer = browser.searchText { text = buffer }
            else {
                let data = try await session.fileSystem.readSearchFile(at: result.url, root: root, limit: ProjectSearchEngine.byteLimit)
                guard let decoded = String(data: data, encoding: .utf8) else { return false }
                text = decoded
            }
            guard navigation == navigationGeneration, session.mode == .project, session.rootDirectory == root,
                  session.terminalGeneration == backendGeneration, browser.selectedFile == selectedFile,
                  browser.searchText == currentText else { return false }
            guard text.utf8.elementsEqual(result.text.utf8) else {
                message = "This file changed. Refresh the search to navigate to its current matches."
                return false
            }
            browser.openSearchText(at: result.url, text: text)
            editor.revealSource(at: result.url, text: text, range: match.range)
            return true
        } catch { message = error.localizedDescription; return false }
    }

    func previewReplacement(file: ProjectSearchResult? = nil, match: NSRange? = nil) {
        guard canReplace else { return }
        // Replace All covers what the filter leaves showing, never hidden files.
        let files = file.map { [$0] } ?? visibleResults
        let template = replacement, request = generation
        isReplacing = true
        task = Task {
            defer { isReplacing = false }
            do {
                var replacements: [ProjectReplacement] = []
                for file in files {
                    replacements.append(try await ProjectSearchEngine.replacement(for: file, match: match, with: template))
                }
                guard request == generation, !Task.isCancelled else { return }
                review = ProjectReplacementReview(replacements: replacements)
            } catch is CancellationError { }
            catch { message = error.localizedDescription }
        }
    }

    func apply(_ review: ProjectReplacementReview) async {
        guard !isReplacing, session.mode == .project else { return }
        self.review = nil
        isReplacing = true
        let root = session.rootDirectory, backendGeneration = session.terminalGeneration
        let fs = session.fileSystem, browser = session.fileBrowser
        var changed = 0
        var failures: [String] = []
        for replacement in review.replacements {
            guard session.mode == .project, session.rootDirectory == root,
                  session.terminalGeneration == backendGeneration, !Task.isCancelled else { break }
            let file = replacement.file
            do {
                if browser.selectedFile == file.url {
                    guard !browser.isSaving, !browser.isPreviewTruncated, !editor.hasPendingCSVEdit,
                          browser.searchText?.utf8.elementsEqual(file.text.utf8) == true else {
                        throw WorkspaceFileSystemError.unsupported("The editor changed or is saving. Search again.")
                    }
                    if let textView = editor.textView, textView.string.utf8.elementsEqual(file.text.utf8) {
                        guard textView.replace(with: replacement.text, range: NSRange(location: 0, length: (file.text as NSString).length),
                            selectedRange: nil, actionName: "Replace in Project") else {
                            throw WorkspaceFileSystemError.unsupported("The editor could not apply the replacement.")
                        }
                    } else { browser.openSearchText(at: file.url, text: replacement.text) }
                    browser.updatePreviewText(replacement.text)
                } else {
                    try await fs.replaceSearchFile(at: file.url, root: root,
                        expected: Data(file.text.utf8), replacement: Data(replacement.text.utf8))
                }
                changed += replacement.changes.count
            } catch { failures.append("\(file.path): \(error.localizedDescription)") }
        }
        isReplacing = false
        schedule()
        message = "Replaced \(changed) matches. Changes in the open editor remain unsaved."
            + (failures.isEmpty ? "" : "\n" + failures.joined(separator: "\n"))
    }
}

struct ProjectReplacementReview: Identifiable {
    let id = UUID()
    let replacements: [ProjectReplacement]
    var count: Int { replacements.reduce(0) { $0 + $1.changes.count } }
}
