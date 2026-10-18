import AppKit
import Foundation

/// Held by the workspace for its entire lifetime; an in-flight native tool
/// also retains the grant until cancellation has finished.
nonisolated final class WorkspaceFolderGrant: @unchecked Sendable {
    let url: URL
    private let scoped: Bool
    init(url: URL) throws {
        self.url = url
        scoped = url.startAccessingSecurityScopedResource()
        #if APP_STORE
        guard scoped else { throw AgentFailure("Folder access was revoked. Select the workspace again.") }
        #endif
    }
    deinit { if scoped { url.stopAccessingSecurityScopedResource() } }
}

@MainActor
enum WorkspaceFolderAuthorization {
    private static let key = "workspace.securityScopedBookmarks"

    static func choose() throws -> WorkspaceFolderGrant? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false; panel.prompt = "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let grant = try WorkspaceFolderGrant(url: url)
        try remember(url)
        return grant
    }

    static func acquire(_ root: URL) throws -> WorkspaceFolderGrant {
        let bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        for (_, data) in bookmarks {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], bookmarkDataIsStale: &stale),
                  root.standardizedFileURL.pathComponents.starts(with: url.standardizedFileURL.pathComponents),
                  let grant = try? WorkspaceFolderGrant(url: url) else { continue }
            if stale { try remember(url) }
            return grant
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.allowsMultipleSelection = false
        panel.directoryURL = root
        panel.message = "Select \(root.lastPathComponent) to authorize this workspace."
        panel.prompt = "Allow Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { throw CancellationError() }
        guard url.standardizedFileURL == root.standardizedFileURL else {
            throw AgentFailure("Select the requested workspace directory, or choose a different project.")
        }
        let grant = try WorkspaceFolderGrant(url: url)
        try remember(url)
        return grant
    }

    private static func remember(_ url: URL) throws {
        let data = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var bookmarks = UserDefaults.standard.dictionary(forKey: key) as? [String: Data] ?? [:]
        bookmarks[url.path] = data
        UserDefaults.standard.set(bookmarks, forKey: key)
    }
}
