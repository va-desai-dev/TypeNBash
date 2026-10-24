//
//  Item.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//
import Foundation
import Observation
import SwiftUI

enum MDViewStyle: Sendable {
    case fancy, plain
}

@MainActor
@Observable
final class FileBrowserModel {
    typealias Entry = WorkspaceFileEntry

    /// The folders beside the editor. Browsing them never touches the open file.
    let tree: FileTreeModel
    private(set) var selectedFile: URL?
    private(set) var preview = FilePreview.none
    var isReadOnly: Bool {
        if case .word = preview { return true }
        if case .document = preview { return true }
        if case .image = preview { return true }
        return false
    }
    var readOnlyLabel: String {
        if case .word = preview { return "Word Document" }
        if case .document = preview { return "PDF Document" }
        if case .image = preview { return "Image File" }
        return ""
    }
    private(set) var isPreviewTruncated = false
    private(set) var hasUnsavedChanges = false
    private(set) var isSaving = false
    private(set) var saveError: String?
    /// True while an in-editor buffer has no file on disk yet (New File). Save
    /// must prompt for a name/extension rather than writing to `selectedFile`.
    private(set) var isUntitled = false
    private(set) var savedPreviewText = ""
    private(set) var editorGitBaseline: String?
    @ObservationIgnored private var editorBaselineTask: Task<Void, Never>?
    private var editorBaselineGeneration = 0
    var comparesEditorWithGit: Bool { fileSystem is LocalWorkspaceFileSystem && !isPreviewTruncated }



    func updatePreviewText(_ newText: String) {
        switch preview {
        case .text: preview = .text(newText)
        case .markdown: preview = .markdown(newText)
        default: return
        }
        hasUnsavedChanges = newText != savedPreviewText
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
            case .text(let contents), .markdown(let contents): contents
            case .table(let table): CSVEngine.generate(from: table)
            default: nil
        }
    }

    var searchText: String? {
        if case .table = preview, !hasUnsavedChanges { return savedPreviewText }
        return editedContents
    }

    /// Search has already read and validated the complete text. Keep the saved
    /// baseline when revealing an existing draft, including a Markdown/CSV source.
    func openSearchText(at url: URL, text: String) {
        let sameFile = selectedFile == url && !isPreviewTruncated && searchText != nil
        previewGeneration &+= 1
        editorBaselineTask?.cancel()
        if !sameFile {
            resetPreviewState()
            savedPreviewText = text
        }
        selectedFile = url
        preview = .text(text)
        isPreviewTruncated = false
        isUntitled = false
        hasUnsavedChanges = text != savedPreviewText
        refreshEditorGitBaseline()
    }

    /// Writes the edited preview back through the workspace filesystem (local or
    /// SSH). Refuses to save a truncated preview, which would discard the rest.
    func save() {
        guard !isSaving, let url = selectedFile, let contents = editedContents else { return }
        guard !isPreviewTruncated else {
            saveError = "This file was truncated for preview; saving would discard the rest."
            return
        }
        let fs = fileSystem
        let data = Data(contents.utf8)
        let generation = previewGeneration
        isSaving = true
        saveError = nil
        Task {
            do {
                try await fs.writeFile(data, to: url)
                isSaving = false
                guard generation == previewGeneration else { return }
                savedPreviewText = contents
                hasUnsavedChanges = editedContents != contents
                refreshEditorGitBaseline()
            } catch {
                isSaving = false
                guard generation == previewGeneration else { return }
                saveError = error.localizedDescription
            }
        }
    }
    
    private var fileSystem: any WorkspaceFileSystem
    private var previewGeneration = 0


    enum FilePreview: Sendable {
        case none
        case text(String)
        case table(CSVTable)
        case image(Data)
        case document(Data)
        case word(WordPreviewDocument)
        case unsupported(String)
        case failed(String)
        case markdown(String)
    }

    convenience init() {
        self.init(fileSystem: LocalWorkspaceFileSystem())
    }

    init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
        tree = FileTreeModel(fileSystem: fileSystem)
    }

    /// Switches workspaces. The open file belonged to the old filesystem, so
    /// unlike browsing, this closes it.
    func use(
        fileSystem: any WorkspaceFileSystem,
        initialDirectory: URL? = nil
    ) {
        self.fileSystem = fileSystem
        previewGeneration &+= 1
        selectedFile = nil
        resetPreviewState()
        tree.use(fileSystem: fileSystem, initialDirectory: initialDirectory)
    }

    /// Re-reads the folders on screen and the editor's Git baseline.
    func refresh() {
        tree.refresh()
        refreshEditorGitBaseline()
    }

    /// Re-reads the open file after something outside the editor rewrote it,
    /// such as a branch switch, and closes it if that removed the file. A
    /// buffer with unsaved edits is left alone; callers refuse to rewrite one.
    func reloadSelectedFile() async {
        guard let url = selectedFile, !hasUnsavedChanges, !isUntitled else { return }
        // The listing supplies the size, which the preview's truncation guard needs.
        guard let listing = try? await fileSystem.contentsOfDirectory(
            at: url.deletingLastPathComponent(), includingHiddenFiles: true
        ), selectedFile == url, !hasUnsavedChanges else { return }
        if let entry = listing.first(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
            loadPreview(for: entry)
        } else {
            previewGeneration &+= 1
            selectedFile = nil
            resetPreviewState()
        }
    }

    private func resetPreviewState() {
        editorBaselineTask?.cancel()
        editorGitBaseline = nil
        preview = .none
        savedPreviewText = ""
        isPreviewTruncated = false
        hasUnsavedChanges = false
        saveError = nil
        isUntitled = false
    }

    /// Opens a fresh, empty editor buffer that isn't backed by a file yet. The
    /// file is only written once the user saves (which prompts for a name and
    /// extension). Mirrors how a text editor's "New Document" works.
    func newFile() {
        editorBaselineTask?.cancel()
        editorGitBaseline = nil
        previewGeneration &+= 1   // cancel any in-flight preview load
        selectedFile = nil
        preview = .text("")
        savedPreviewText = ""
        isPreviewTruncated = false
        isUntitled = true
        hasUnsavedChanges = true
        saveError = nil
    }

    /// Writes the untitled buffer to a new file in the tree's target folder. `name`
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
        let directory = tree.targetDirectory
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
            savedPreviewText = contents
            refreshEditorGitBaseline()
            isUntitled = false
            hasUnsavedChanges = false
            isSaving = false
            tree.didCreate(target)
        } catch {
            isSaving = false
            saveError = error.localizedDescription
            return error.localizedDescription
        }
        return nil
    }

    /// Creates a folder in the tree's target folder through the workspace filesystem
    /// (local or SSH — the model never knows which). Returns an error message on
    /// failure, or `nil` on success.
    func newFolder(named name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "The folder name can't be empty." }
        guard !trimmed.hasPrefix("/"), !trimmed.contains("/") else {
            return "The folder name can't contain “/”."
        }
        let directory = tree.targetDirectory
        let target: URL
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
            target = directory.appendingPathComponent(uniqueName, isDirectory: true)
            try await fileSystem.createDirectory(at: target)
        } catch {
            return error.localizedDescription
        }
        tree.didCreate(target)
        return nil
    }

    /// Whether a deletion can be undone from the Trash. SSH deletes for good.
    var deletionIsRecoverable: Bool { fileSystem.movesDeletedItemsToTrash }

    /// Whether deleting `url` would take the open file, unsaved edits and all.
    func deletionDiscardsEdits(_ url: URL) -> Bool {
        hasUnsavedChanges && selectedFile.map { Self.url($0, isWithin: url) } == true
    }

    /// Deletes a file or folder through the workspace filesystem — to the
    /// Trash locally, permanently over SSH — closing the open file if it went
    /// with it. Returns an error message, or nil on success.
    ///
    /// The folder being browsed, the project boundary and the home folder are
    /// refused, along with anything containing them.
    func delete(_ entry: Entry) async -> String? {
        if isProtected(entry.url) {
            return "“\(entry.label)” contains the folder you’re browsing, the project, or your home folder, so it can’t be deleted here."
        }
        // Both are worked out while the item still exists: standardizing a
        // path consults the disk, dropping a leading `/private` only from a
        // path that exists, so afterwards they'd stop matching.
        let closesOpenFile = selectedFile.map { Self.url($0, isWithin: entry.url) } == true
        let key = FileTreeModel.key(entry.url)
        do {
            try await fileSystem.deleteItem(at: entry.url)
        } catch {
            return error.localizedDescription
        }
        if closesOpenFile {
            previewGeneration &+= 1
            selectedFile = nil
            resetPreviewState()
        }
        tree.didRemove(entry.url, key: key)
        // A deleted tracked file shows up in Changes.
        NotificationCenter.default.post(name: .gitRepositoryDidChange, object: self)
        return nil
    }

    /// Renames a file or folder where it is, through the workspace filesystem.
    /// Returns an error message, or nil on success. The open file follows a
    /// rename of itself or of a folder above it, keeping its buffer and any
    /// unsaved edits. The same folders as `delete(_:)` are refused.
    func rename(_ entry: Entry, to newName: String) async -> String? {
        let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/") else {
            return "Enter a name that isn’t empty and doesn’t contain “/”."
        }
        guard name != entry.label else { return nil }
        if isProtected(entry.url) {
            return "“\(entry.label)” contains the folder you’re browsing, the project, or your home folder, so it can’t be renamed here."
        }
        return await relocate(entry, to: entry.url.deletingLastPathComponent()
            .appendingPathComponent(name, isDirectory: entry.isDirectory))
    }

    /// Moves a file or folder into `folder`, keeping its name, as a drag in
    /// the tree does. Dropping where it already is does nothing; a folder
    /// can't go inside itself. Otherwise it behaves like `rename(_:to:)`.
    func move(_ entry: Entry, into folder: URL) async -> String? {
        if Self.url(folder, isWithin: entry.url) {
            return "“\(entry.label)” can’t be moved into itself."
        }
        let parent = entry.url.deletingLastPathComponent()
        guard folder.standardizedFileURL.path != parent.standardizedFileURL.path else { return nil }
        if isProtected(entry.url) {
            return "“\(entry.label)” contains the folder you’re browsing, the project, or your home folder, so it can’t be moved here."
        }
        return await relocate(entry, to: folder.appendingPathComponent(entry.label, isDirectory: entry.isDirectory))
    }

    /// Moves `entry` to `destination`, never replacing anything there, and
    /// carries the open file and the tree along.
    private func relocate(_ entry: Entry, to destination: URL) async -> String? {
        // Taken before the move, while both paths standardize alike; see `delete(_:)`.
        let key = FileTreeModel.key(entry.url)
        let openSuffix = selectedFile.flatMap { open -> String? in
            guard Self.url(open, isWithin: entry.url) else { return nil }
            return String(open.standardizedFileURL.path.dropFirst(entry.url.standardizedFileURL.path.count))
        }
        do {
            try await fileSystem.moveItem(at: entry.url, to: destination)
        } catch {
            return error.localizedDescription
        }
        if let openSuffix {
            selectedFile = URL(filePath: destination.path + openSuffix)
            refreshEditorGitBaseline()
        }
        tree.didMove(entry.url, key: key, to: destination)
        // A moved tracked file shows up in Changes.
        NotificationCenter.default.post(name: .gitRepositoryDidChange, object: self)
        return nil
    }

    /// The folder being browsed, the project boundary and the home folder,
    /// or anything containing them: changing those would pull the tree or
    /// the project out from under itself.
    private func isProtected(_ url: URL) -> Bool {
        [tree.directory, tree.navigationRoot, fileSystem.homeDirectory].compactMap { $0 }
            .contains { Self.url($0, isWithin: url) }
    }

    /// Whether `url` is `folder` itself or somewhere inside it.
    nonisolated static func url(_ url: URL, isWithin folder: URL) -> Bool {
        let path = url.standardizedFileURL.path, folderPath = folder.standardizedFileURL.path
        return path == folderPath || path.hasPrefix(folderPath.hasSuffix("/") ? folderPath : folderPath + "/")
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

    /// Opens a file in the editor, or hands a folder to the tree.
    func select(_ entry: Entry) {
        if entry.isDirectory {
            tree.activate(entry.url)
            return
        }
        tree.reveal(entry.url)
        selectedFile = entry.url
        loadPreview(for: entry)
    }

    private func loadPreview(for entry: Entry) {
        preview = .none
        isPreviewTruncated = false
        editorBaselineTask?.cancel()
        editorGitBaseline = nil
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
            || ext == "docx"
        let limit = isBinaryPreview ? Self.binaryPreviewByteLimit : Self.previewByteLimit

        Task {
            do {
                // The workspace filesystem is the "connection": local memory-maps a
                // prefix, SSH streams a prefix over the wire — either way we get up to
                // `limit` bytes and render them identically. No local/remote branch.
                let data = try await fs.readFile(at: fileURL, maximumByteCount: limit + (ext == "docx" ? 1 : 0))
                guard generation == previewGeneration else { return }
                let parsed = await Task.detached(priority: .userInitiated) {
                    Self.makePreview(from: data, fileExtension: ext, totalByteCount: totalByteCount, limit: limit)
                }.value
                guard generation == previewGeneration else { return }
                preview = parsed
                switch parsed {
                case .text(let contents), .markdown(let contents): savedPreviewText = contents
                case .table: savedPreviewText = String(data: data, encoding: .utf8) ?? ""
                default: savedPreviewText = ""
                }
                // Only text previews can be safely saved after truncation; binary
                // previews never round-trip through the editor's save path.
                isPreviewTruncated = !isBinaryPreview && (totalByteCount ?? 0) > limit
                refreshEditorGitBaseline()
                hasUnsavedChanges = false
                saveError = nil
            } catch {
                guard generation == previewGeneration else { return }
                preview = .failed(error.localizedDescription)
            }
        }
    }

    /// Cache remote HEAD independently of the draft. Switching hosts/files or a
    /// newer refresh invalidates in-flight replies, even for identical paths.
    func refreshEditorGitBaseline() {
        editorBaselineTask?.cancel()
        editorBaselineGeneration &+= 1
        guard !(fileSystem is LocalWorkspaceFileSystem), !isPreviewTruncated,
              case .text = preview, let url = selectedFile else { return }
        let fs = fileSystem
        let generation = previewGeneration
        let request = editorBaselineGeneration
        editorBaselineTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            let baseline = try? await fs.editorGitBaseline(at: url)
            guard !Task.isCancelled, let self, self.previewGeneration == generation,
                  self.editorBaselineGeneration == request else { return }
            self.editorGitBaseline = baseline
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
        if fileExtension.lowercased() == "docx" {
            guard !data.isEmpty else { return .failed("This Word document is empty.") }
            guard data.count <= limit, (totalByteCount ?? data.count) <= limit else {
                return .unsupported("This Word document exceeds the 25 MB preview limit.")
            }
            do {
                return .word(try WordPreviewDocument(data: data))
            } catch {
                return .failed("Couldn’t prepare the Word preview: \(error.localizedDescription)")
            }
        }
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
