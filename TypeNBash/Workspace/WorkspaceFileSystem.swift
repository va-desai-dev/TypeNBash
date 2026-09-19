import Foundation

/// `nonisolated` because the target's default isolation is `MainActor`, and
/// this is a pure `Sendable` value the file systems produce off the main actor
/// and `GitDiffFile` reads from its own `nonisolated` context.
nonisolated struct WorkspaceFileEntry: Identifiable, Hashable, Sendable {
    let url: URL
    let isDirectory: Bool
    let byteCount: Int?

    var id: URL { url }

    var icon: String {
        Self.icon(for: url, isDirectory: isDirectory)
    }
    var label: String {
        url.lastPathComponent
    }

    /// The symbol for a path, with no entry needed to hang it on.
    ///
    /// Shared with `GitDiffFile`: its paths are repository-relative and never
    /// come from a directory listing, and a deleted one has no file on disk to
    /// build an entry from either.
    static func icon(for url: URL, isDirectory: Bool = false) -> String {
        if isDirectory { return "folder.fill" }
        switch url.pathExtension.lowercased() {
            case "swift": return "swift"
            case "json", "yaml", "yml", "toml": return "curlybraces"
            case "md", "txt", "log": return "doc.plaintext"
            case "png", "jpg", "jpeg", "gif", "heic": return "photo"
            case "sh", "zsh", "bash": return "terminal"
            default: return "doc"
        }
    }
}

protocol WorkspaceFileSystem: AnyObject {
    var homeDirectory: URL { get }

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry]

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data
    func writeFile(_ data: Data, to url: URL) async throws
    func createDirectory(at url: URL) async throws
    func createFile(_ data: Data, at url: URL) async throws
}

extension WorkspaceFileSystem {
    func createFile(_ data: Data, at url: URL) async throws {
        throw WorkspaceFileSystemError.unsupported("This filesystem cannot create project definitions.")
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
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey]
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
                byteCount: values.fileSize
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

    func createDirectory(at url: URL) async throws {
        // No intermediates: a "New Folder" is one level, and a name that already
        // exists should surface as an error rather than silently succeed.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
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
