import Foundation

/// `nonisolated` because the target's default isolation is `MainActor`, and
/// this is a pure `Sendable` value the file systems produce off the main actor
/// and `GitDiffFile` reads from its own `nonisolated` context.
nonisolated struct WorkspaceFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let byteCount: Int?
    /// Nil when the filesystem couldn't report it; sorts as the oldest.
    var modificationDate: Date? = nil

    var id: URL { url }

    var icon: FileTypeIcon {
        Self.icon(for: url, isDirectory: isDirectory)
    }
    var label: String {
        url.lastPathComponent
    }

    /// The icon for a path, with no entry needed to hang it on.
    ///
    /// Shared with `GitDiffFile`: its paths are repository-relative and never
    /// come from a directory listing, and a deleted one has no file on disk to
    /// build an entry from either.
    static func icon(for url: URL, isDirectory: Bool = false) -> FileTypeIcon {
        FileTypeIcon.icon(for: url, isDirectory: isDirectory)
    }
}

protocol WorkspaceFileSystem: AnyObject {
    var homeDirectory: URL { get }

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry]

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data
    /// Remote HEAD content for the editor; nil falls back to the saved buffer.
    func editorGitBaseline(at url: URL) async throws -> String?
    func writeFile(_ data: Data, to url: URL) async throws
    func createDirectory(at url: URL) async throws
    func createFile(_ data: Data, at url: URL) async throws
    /// Whether `deleteItem` moves to the Trash, so it can be put back. A
    /// filesystem with no Trash, such as an SSH host's, deletes for good.
    var movesDeletedItemsToTrash: Bool { get }
    /// Removes a file, or a folder and everything in it. A link is removed
    /// itself; what it points to is left alone.
    func deleteItem(at url: URL) async throws
    /// Moves or renames a file or folder. Fails rather than replace anything
    /// already at `destination`, except the item itself on a case-insensitive
    /// disk, so `readme` can become `README`.
    func moveItem(at url: URL, to destination: URL) async throws
    func searchEntries(at directory: URL, root: URL) async throws -> [WorkspaceFileEntry]
    func readSearchFile(at url: URL, root: URL, limit: Int) async throws -> Data
    func replaceSearchFile(at url: URL, root: URL, expected: Data, replacement: Data) async throws
    /// Files and folders under `root` whose names contain `query`, ignoring case,
    /// at most `limit` of them. Links are listed but not followed.
    func findFiles(named query: String, under root: URL, includingHiddenFiles: Bool, limit: Int) async throws -> [WorkspaceFileEntry]
    /// Folders among those last passed to `watch` whose listings changed on disk.
    /// Never yields where the filesystem can't watch.
    var folderChanges: AsyncStream<URL> { get }
    func watch(_ folders: [URL])
}

extension WorkspaceFileSystem {
    func searchEntries(at directory: URL, root: URL) async throws -> [WorkspaceFileEntry] {
        throw WorkspaceFileSystemError.unsupported("Project search is unavailable on this filesystem.")
    }
    func readSearchFile(at url: URL, root: URL, limit: Int) async throws -> Data {
        throw WorkspaceFileSystemError.unsupported("Project search is unavailable on this filesystem.")
    }
    func replaceSearchFile(at url: URL, root: URL, expected: Data, replacement: Data) async throws {
        throw WorkspaceFileSystemError.unsupported("Project replacement is unavailable on this filesystem.")
    }
    func editorGitBaseline(at url: URL) async throws -> String? { nil }
    func findFiles(named query: String, under root: URL, includingHiddenFiles: Bool, limit: Int) async throws -> [WorkspaceFileEntry] {
        throw WorkspaceFileSystemError.unsupported("File search is unavailable on this filesystem.")
    }
    var folderChanges: AsyncStream<URL> { AsyncStream { $0.finish() } }
    func watch(_ folders: [URL]) {}

    func createFile(_ data: Data, at url: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("This filesystem cannot create project definitions.")
    }
    var movesDeletedItemsToTrash: Bool { false }
    func deleteItem(at url: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("This filesystem cannot delete files.")
    }
    func moveItem(at url: URL, to destination: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("This filesystem cannot rename files.")
    }
}

final class LocalWorkspaceFileSystem: WorkspaceFileSystem {

    let homeDirectory = FileManager.default.homeDirectoryForCurrentUser

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry] {
        let options: FileManager.DirectoryEnumerationOptions = includingHiddenFiles
            ? []
            : [.skipsHiddenFiles]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        return try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: options
        ).map { url in
            var values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true {
                values = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)) ?? values
            }
            return WorkspaceFileEntry(
                url: url,
                isDirectory: values.isDirectory == true,
                byteCount: values.fileSize,
                modificationDate: values.contentModificationDate
            )
        }
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        // Memory-map and hand back at most `maximumByteCount` bytes (a prefix), so a
        // huge file previews instantly instead of erroring. mmap only pages in what
        // the reader actually touches.
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        return data.count > maximumByteCount ? data.prefix(maximumByteCount) : data
    }

    func writeFile(_ data: Data, to url: URL) async throws {
        try data.write(to: url, options: .atomic)
    }

    func createFile(_ data: Data, at url: URL) async throws {
        try data.write(to: url, options: .withoutOverwriting)
    }

    func findFiles(named query: String, under root: URL, includingHiddenFiles: Bool, limit: Int) async throws -> [WorkspaceFileEntry] {
        try await Self.find(query, under: root, includingHiddenFiles: includingHiddenFiles, limit: limit)
    }

    /// Off the main actor, and stops walking once the search is cancelled.
    @concurrent private nonisolated static func find(
        _ query: String, under root: URL, includingHiddenFiles: Bool, limit: Int
    ) async throws -> [WorkspaceFileEntry] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walk = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: includingHiddenFiles ? [] : [.skipsHiddenFiles]
        ) else { return [] }
        var result: [WorkspaceFileEntry] = []
        while result.count < limit, let url = walk.nextObject() as? URL {
            try Task.checkCancellation()
            guard url.lastPathComponent.range(of: query, options: .caseInsensitive) != nil else { continue }
            // A linked folder lists as a folder, as in `contentsOfDirectory`, but isn't walked.
            var values = try? url.resourceValues(forKeys: keys)
            if values?.isSymbolicLink == true { values = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys)) ?? values }
            result.append(WorkspaceFileEntry(
                url: url, isDirectory: values?.isDirectory == true,
                byteCount: values?.fileSize, modificationDate: values?.contentModificationDate
            ))
        }
        return result
    }

    func createDirectory(at url: URL) async throws {
        // No intermediates: a "New Folder" is one level, and a name that already
        // exists should surface as an error rather than silently succeed.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }

    var movesDeletedItemsToTrash: Bool { true }

    func deleteItem(at url: URL) async throws {
        try FileManager.default.trashItem(at: url, resultingItemURL: nil)
    }

    /// `FileManager` already refuses an existing destination and allows a
    /// case-only rename.
    func moveItem(at url: URL, to destination: URL) async throws {
        try FileManager.default.moveItem(at: url, to: destination)
    }
}

enum WorkspaceFileSystemError: LocalizedError {
    case fileTooLarge(limit: Int)
    case invalidResponse(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let limit):
            "This file is larger than the \(limit / 1_024) KB preview limit."
        case .invalidResponse(let message):
            "The remote filesystem returned an invalid response: \(message)"
        case .unsupported(let message):
            message
        }
    }
}
