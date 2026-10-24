import Foundation
import BibTeXViewer

/// Lets `BibLibrary` read and write through the window's workspace file
/// system, so a project's .bib works the same on this Mac and over SSH.
final class WorkspaceBibAccess: BibFileAccess {
    private let fileSystem: any WorkspaceFileSystem
    private let isLocal: Bool
    /// Discovery and watching on this Mac reuse the kit's kqueue code.
    private let local = LocalBibFileAccess()

    init(fileSystem: any WorkspaceFileSystem, isLocal: Bool) {
        self.fileSystem = fileSystem
        self.isLocal = isLocal
    }

    /// Gates "Reveal in Finder". Choosing a file goes through the app's own
    /// browser, so it never needs the open panel.
    var canBrowseLocally: Bool { isLocal }

    func read(_ url: URL) async throws -> Data {
        try await fileSystem.readFile(at: url, maximumByteCount: 32 << 20)
    }

    func write(_ data: Data, to url: URL) async throws {
        try await fileSystem.writeFile(data, to: url)
    }

    func findBibFiles(in root: URL) async throws -> [URL] {
        if isLocal { return try await local.findBibFiles(in: root) }
        // Each remote listing is a round trip, so search only near the root.
        // Anything deeper can still be chosen with the browser.
        var found: [URL] = []
        var level = [root]
        for _ in 0..<2 {
            var next: [URL] = []
            for directory in level {
                try Task.checkCancellation()
                guard let entries = try? await fileSystem.contentsOfDirectory(
                    at: directory, includingHiddenFiles: false) else { continue }
                for entry in entries {
                    if entry.isDirectory {
                        next.append(entry.url)
                    } else if entry.url.pathExtension.lowercased() == "bib" {
                        found.append(entry.url.standardizedFileURL)
                    }
                }
            }
            level = next
        }
        return found.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Remote files aren't watched; the list refreshes after its own edits.
    func watch(_ url: URL, onChange: @escaping @MainActor () -> Void) -> (any BibWatchToken)? {
        isLocal ? local.watch(url, onChange: onChange) : nil
    }
}
