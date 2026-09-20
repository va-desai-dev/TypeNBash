//
//  Item.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//
import Foundation
import Observation
import SwiftUI

@MainActor
@Observable
final class FileBrowserModel {
    typealias Entry = WorkspaceFileEntry

    private(set) var directory = FileManager.default.homeDirectoryForCurrentUser
    private(set) var entries: [Entry] = []
    private(set) var selectedFile: URL?
    private(set) var preview = FilePreview.none
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isPreviewTruncated = false
    private(set) var hasUnsavedChanges = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    /// True while an in-editor buffer has no file on disk yet (New File). Save
    /// must prompt for a name/extension rather than writing to `selectedFile`.
    private(set) var isUntitled = false
    var showsHiddenFiles = false {
        didSet { refresh() }
    }



    func updatePreviewText(_ newText: String) {
        if case .text = preview {
            preview = .text(newText)
            hasUnsavedChanges = true
        }
    }

    /// Takes a snapshot back from the spreadsheet grid, which edits its own
    /// `CSVStorage` in place. Without this the cells would change on screen and
    /// ⌘S would have nothing to write.
    func updatePreviewTable(_ newTable: CSVTable) {
        if case .table = preview {
            preview = .table(newTable)
            hasUnsavedChanges = true
        }
    }

    /// What ⌘S writes: the editor's text, or the grid re-serialized to CSV.
    private var editedContents: String? {
        switch preview {
            case .text(let contents): contents
            case .table(let table): CSVEngine.generate(from: table)
            default: nil
        }
    }

    /// Writes the edited preview back through the workspace filesystem (local or
    /// SSH). Refuses to save a truncated preview, which would discard the rest.
    func save() {
        guard let url = selectedFile, let contents = editedContents else { return }
        guard !isPreviewTruncated else {
            saveError = "This file was truncated for preview; saving would discard the rest."
            return
        }
        let fs = fileSystem
        let data = Data(contents.utf8)
        isSaving = true
        saveError = nil
        Task {
            do {
                try await fs.writeFile(data, to: url)
                isSaving = false
                hasUnsavedChanges = false
            } catch {
                isSaving = false
                saveError = error.localizedDescription
            }
        }
    }

    

    private var fileSystem: any WorkspaceFileSystem
    private var refreshGeneration = 0
    private var previewGeneration = 0

    /// Shared local/SSH project boundary; nil permits unrestricted browsing.
    var navigationRoot: URL?

    /// Visited directories, oldest first, with `historyIndex` marking the one
    /// on screen. Kept private so the trail can only be walked through
    /// `navigate`, `goBack`, and `goForward`.
    private var history: [URL] = []
    private var historyIndex = 0

    private static let historyLimit = 128


    enum FilePreview: Sendable {
        case none
        case text(String)
        case table(CSVTable)
        case image(Data)
        case document(Data)
        case unsupported(String)
        case failed(String)
        case markdown(String)
    }

    init() {
        let fileSystem = LocalWorkspaceFileSystem()
        self.fileSystem = fileSystem
        directory = fileSystem.homeDirectory.standardizedFileURL
        history = [directory]
        historyIndex = 0
    }

    init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
        directory = fileSystem.homeDirectory.standardizedFileURL
        history = [directory]
        historyIndex = 0
    }

    func use(
        fileSystem: any WorkspaceFileSystem,
        initialDirectory: URL? = nil
    ) {
        refreshGeneration &+= 1
        self.fileSystem = fileSystem
        // A new workspace starts a new trail: back must never walk into paths
        // that belonged to a filesystem this model no longer talks to.
        let target = (initialDirectory ?? fileSystem.homeDirectory).standardizedFileURL
        history = [target]
        historyIndex = 0
        show(target)
    }

    /// Moves to `url` and records it, discarding any forward entries — a new
    /// destination forks the trail the way a browser's address bar does.
    func navigate(to url: URL) {
        let target = url.standardizedFileURL
        guard allowsNavigation(to: target) else { return }
        guard history.isEmpty || history[historyIndex] != target else {
            show(target)
            return
        }

        if historyIndex < history.count - 1 {
            history.removeSubrange((historyIndex + 1)...)
        }
        history.append(target)
        // The terminal reports a directory on every prompt, so an unbounded
        // trail would grow for as long as the window stays open.
        if history.count > Self.historyLimit {
            history.removeFirst(history.count - Self.historyLimit)
        }
        historyIndex = history.count - 1
        show(target)
    }

    /// Returns to the previously visited directory. Distinct from `goUp`: the
    /// trail is where the user (or the terminal) has actually been, which is
    /// what makes a jump out of a project root recoverable in one click.
    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        show(history[historyIndex])
    }

    func goForward() {
        guard canGoForward else { return }
        historyIndex += 1
        show(history[historyIndex])
    }

    var canGoBack: Bool {
        historyIndex > 0 && allowsNavigation(to: history[historyIndex - 1])
    }

    var canGoForward: Bool {
        historyIndex < history.count - 1 && allowsNavigation(to: history[historyIndex + 1])
    }

    var canGoUp: Bool {
        let parent = directory.deletingLastPathComponent()
        return parent.path != directory.path && allowsNavigation(to: parent)
    }

    private func allowsNavigation(to url: URL) -> Bool {
        guard let navigationRoot else { return true }
        return url.standardizedFileURL.pathComponents.starts(with: navigationRoot.standardizedFileURL.pathComponents)
    }

    /// Points the pane at `directory` without touching the trail, so the four
    /// navigation entry points can't disagree about how to load a folder.
    private func show(_ directory: URL) {
        previewGeneration &+= 1
        self.directory = directory
        selectedFile = nil
        resetPreviewState()
        refresh()
    }

    private func resetPreviewState() {
        preview = .none
        isPreviewTruncated = false
        hasUnsavedChanges = false
        saveError = nil
        isUntitled = false
    }

    /// Opens a fresh, empty editor buffer that isn't backed by a file yet. The
    /// file is only written once the user saves (which prompts for a name and
    /// extension). Mirrors how a text editor's "New Document" works.
    func newFile() {
        previewGeneration &+= 1   // cancel any in-flight preview load
        selectedFile = nil
        preview = .text("")
        isPreviewTruncated = false
        isUntitled = true
        hasUnsavedChanges = true
        saveError = nil
    }

    /// Writes the untitled buffer to a new file in the current directory. `name`
    /// and `ext` come from the Save prompt; a blank extension falls back to txt.
    /// The final name is uniqued so it never overwrites an existing file.
    func saveNewFile(named name: String, extension ext: String) async -> String? {
        guard case .text(let contents) = preview else {
            return "There is nothing to save."
        }
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return "The file name can't be empty." }
        guard !trimmedName.hasPrefix("/"), !trimmedName.contains("/") else {
            return "The file name can't contain “/”."
        }
        let cleanedExt = ext
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let effectiveExt = cleanedExt.isEmpty ? "txt" : cleanedExt
        let fileName = "\(trimmedName).\(effectiveExt)"

        isSaving = true
        saveError = nil
        do {
            let existing = try await fileSystem.contentsOfDirectory(
                at: directory,
                includingHiddenFiles: true
            )
            let unique = Self.uniqueFileName(
                fileName,
                avoiding: Set(existing.map { $0.url.lastPathComponent })
            )
            let target = directory.appendingPathComponent(unique, isDirectory: false)
            try await fileSystem.writeFile(Data(contents.utf8), to: target)
            selectedFile = target
            isUntitled = false
            hasUnsavedChanges = false
            isSaving = false
            refresh()
        } catch {
            isSaving = false
            saveError = error.localizedDescription
            return error.localizedDescription
        }
        return nil
    }

    /// Creates a folder in the current directory through the workspace filesystem
    /// (local or SSH — the model never knows which). Returns an error message on
    /// failure, or `nil` on success.
    func newFolder(named name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The folder name can't be empty." }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("/") else {
            return "The folder name can't contain “/”."
        }
        do {
            // Resolve a non-colliding name up front (Finder-style " 2", " 3", …) so
            // we never overwrite an existing folder the way `mkdir` in a terminal
            // would. `includingHiddenFiles: true` also avoids colliding with a
            // hidden entry the user can't currently see.
            let existing = try await fileSystem.contentsOfDirectory(
                at: directory,
                includingHiddenFiles: true
            )
            let taken = Set(existing.map { $0.url.lastPathComponent })
            let uniqueName = Self.uniqueName(trimmed, avoiding: taken)
            let target = directory.appendingPathComponent(uniqueName, isDirectory: true)
            try await fileSystem.createDirectory(at: target)
        } catch {
            return error.localizedDescription
        }
        refresh()
        return nil
    }

    /// Returns `base` if free, otherwise the first available "base N" (N ≥ 2),
    /// matching Finder's untitled-folder suffixing.
    nonisolated static func uniqueName(_ base: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var index = 2
        while taken.contains("\(base) \(index)") { index += 1 }
        return "\(base) \(index)"
    }

    /// Like `uniqueName` but keeps the extension intact: "notes.txt" → "notes 2.txt".
    nonisolated static func uniqueFileName(_ fileName: String, avoiding taken: Set<String>) -> String {
        guard taken.contains(fileName) else { return fileName }
        let url = URL(fileURLWithPath: fileName)
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        func candidate(_ index: Int) -> String {
            ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
        }
        var index = 2
        while taken.contains(candidate(index)) { index += 1 }
        return candidate(index)
    }

    func goUp() {
        guard canGoUp else { return }
        let parent = directory.deletingLastPathComponent()
        if parent.path != directory.path { navigate(to: parent) }
    }

    func refresh() {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        let requestedDirectory = directory
        let includesHiddenFiles = showsHiddenFiles
        let requestedFileSystem = fileSystem
        isLoading = true

        Task {
            do {
                let contents = try await requestedFileSystem.contentsOfDirectory(
                    at: requestedDirectory,
                    includingHiddenFiles: includesHiddenFiles
                )
                guard generation == refreshGeneration else { return }
                entries = contents.sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent.localizedStandardCompare(
                        $1.url.lastPathComponent
                    ) == .orderedAscending
                }
                errorMessage = nil
                isLoading = false
            } catch {
                guard generation == refreshGeneration else { return }
                entries = []
                errorMessage = error.localizedDescription
                isLoading = false
            }
        }
    }

    func select(_ entry: Entry) {
        if entry.isDirectory {
            navigate(to: entry.url)
            return
        }
        selectedFile = entry.url
        loadPreview(for: entry)
    }

    private func loadPreview(for entry: Entry) {
        previewGeneration &+= 1
        isUntitled = false
        let generation = previewGeneration
        let fs = fileSystem
        let fileURL = entry.url
        let totalByteCount = entry.byteCount
        let ext = fileURL.pathExtension.lowercased()
        // Images and PDFs must arrive whole to decode, so they get a larger cap;
        // text previews stay tightly bounded (they're safe to truncate mid-file).
        let isBinaryPreview = Self.imageExtensions.contains(ext)
            || Self.documentExtensions.contains(ext)
        let limit = isBinaryPreview ? Self.binaryPreviewByteLimit : Self.previewByteLimit

        Task {
            do {
                // The workspace filesystem is the "connection": local memory-maps a
                // prefix, SSH streams a prefix over the wire — either way we get up to
                // `limit` bytes and render them identically. No local/remote branch.
                let data = try await fs.readFile(at: fileURL, maximumByteCount: limit)
                guard generation == previewGeneration else { return }
                let parsed = await Task.detached(priority: .userInitiated) {
                    Self.makePreview(from: data, fileExtension: ext, totalByteCount: totalByteCount, limit: limit)
                }.value
                guard generation == previewGeneration else { return }
                preview = parsed
                // Only text previews can be safely saved after truncation; binary
                // previews never round-trip through the editor's save path.
                isPreviewTruncated = !isBinaryPreview && (totalByteCount ?? 0) > limit
                hasUnsavedChanges = false
                saveError = nil
            } catch {
                guard generation == previewGeneration else { return }
                preview = .failed(error.localizedDescription)
            }
        }
    }

    /// Keep remote text previews bounded even though the editor handles larger local documents.
    nonisolated static let previewByteLimit = 2 * 1024 * 1024

    /// Images and PDFs need to arrive whole to render, so allow a larger prefix.
    nonisolated static let binaryPreviewByteLimit = 25 * 1024 * 1024

    /// File extensions rendered by `ImagePreviewView` via `NSImage`.
    nonisolated static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "heic", "heif",
        "bmp", "tiff", "tif", "webp", "ico", "icns"
    ]

    nonisolated static let markdownExtension: Set<String> = ["md"]

    /// File extensions rendered by the spreadsheet grid instead of the editor.
    ///
    /// Only comma-separated data: `CSVEngine` splits on commas, so a `.tsv`
    /// would arrive as one column per row.
    nonisolated static let tableExtensions: Set<String> = ["csv"]

    /// File extensions rendered by the PDF viewer.
    nonisolated static let documentExtensions: Set<String> = ["pdf"]

    /// Turns fetched bytes into a preview. Shared by the local and remote paths so
    /// rendering is identical regardless of where the file lives.
    nonisolated static func makePreview(
        from data: Data,
        fileExtension: String,
        totalByteCount: Int?,
        limit: Int
    ) -> FilePreview {
        guard !data.isEmpty else { return .text("") }

        // Route recognized binary types to their dedicated viewers before the
        // null-byte check below would reject them as unpreviewable.
        if imageExtensions.contains(fileExtension) { return .image(data) }
        if documentExtensions.contains(fileExtension) { return .document(data) }


        // A null byte in the first 8 KB marks the payload as binary.
        guard !data.prefix(8_192).contains(0) else {
            return .unsupported("Binary file — preview is not available.")
        }

        guard var text = String(data: data, encoding: .utf8) else {
            return .unsupported("This text encoding is not supported yet.")
        }

        // Tabular data goes to the grid rather than the editor. A file with no
        // header row to read falls through to the text editor instead of
        // presenting an empty spreadsheet. Note this returns before the
        // truncation notice below, which as a CSV line would read as a row.
        if tableExtensions.contains(fileExtension) {
            let table = CSVEngine.parse(text)
            if !table.isEmpty { return .table(table) }
        }
        if markdownExtension.contains(fileExtension) { return .markdown(text) }

        if let totalByteCount, totalByteCount > limit {
            let totalMB = Double(totalByteCount) / (1024.0 * 1024.0)
            text.append(String(
                format: "\n\n--- [Preview truncated. Showing first %d MB of %.2f MB file] ---",
                limit / (1024 * 1024),
                totalMB
            ))
        }
        return .text(text)
    }
}
