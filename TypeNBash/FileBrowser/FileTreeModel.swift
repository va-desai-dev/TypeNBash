import Defaults
import Foundation
import Observation

/// How the browser lays out a folder: its entries alone, or with folders that
/// expand in place.
enum FileTreeLayout: Int, CaseIterable, Identifiable, Sendable {
    case list, tree

    var id: Self { self }
    var title: String {
        switch self {
            case .list: "List"
            case .tree: "Tree"
        }
    }
}

enum FileTreeSortKey: Int, CaseIterable, Identifiable, Sendable {
    case name, kind, dateModified, size

    var id: Self { self }
    var title: String {
        switch self {
            case .name: "Name"
            case .kind: "Kind"
            case .dateModified: "Date Modified"
            case .size: "Size"
        }
    }
}

/// One visible line of the browser: an entry and how deep under the root it sits.
struct FileTreeRow: Identifiable, Hashable {
    let entry: WorkspaceFileEntry
    let depth: Int
    let isExpanded: Bool
    let isLoading: Bool
    let failure: String?

    var id: String { FileTreeModel.key(entry.url) }
}

/// The browsable side of the file pane: the root folder and its history, which
/// folders are expanded beneath it, and the listings that fill them. It knows
/// nothing about the open file, so browsing never disturbs the editor.
///
/// Folders are read lazily, one listing per expanded folder, through the same
/// workspace filesystem for local and SSH alike.
@MainActor
@Observable
final class FileTreeModel {
    typealias Entry = WorkspaceFileEntry

    private(set) var directory: URL
    /// The root and every expanded folder, flattened in display order.
    private(set) var rows: [FileTreeRow] = []
    /// The highlighted row's id. In tree layout it also picks the folder that
    /// New File and New Folder write into.
    var selectedID: String?
    private(set) var errorMessage: String?
    private(set) var isLoading = false

    var showsHiddenFiles = false {
        didSet { refresh() }
    }
    var layout = UserDefaults.standard[.fileBrowserLayout] {
        didSet {
            UserDefaults.standard[.fileBrowserLayout] = layout
            // Cached folders show at once; the refresh reads any opened since.
            rebuildRows()
            refresh()
        }
    }
    var sortKey = UserDefaults.standard[.fileBrowserSortKey] {
        didSet {
            UserDefaults.standard[.fileBrowserSortKey] = sortKey
            resort()
        }
    }
    var sortsAscending = UserDefaults.standard[.fileBrowserSortsAscending] {
        didSet {
            UserDefaults.standard[.fileBrowserSortsAscending] = sortsAscending
            resort()
        }
    }
    var foldersFirst = UserDefaults.standard[.fileBrowserFoldersFirst] {
        didSet {
            UserDefaults.standard[.fileBrowserFoldersFirst] = foldersFirst
            resort()
        }
    }

    /// Shared local/SSH project boundary; nil permits unrestricted browsing.
    var navigationRoot: URL?

    private var fileSystem: any WorkspaceFileSystem
    /// Sorted listings by folder key. Only folders under the current root.
    private var listings: [String: [Entry]] = [:]
    private var expanded: Set<String> = []
    private var failures: [String: String] = [:]
    /// Keys of the root and expanded folders on screen, as last passed to `watch`.
    private var watched: Set<String> = []
    private var changesTask: Task<Void, Never>?
    /// The newest request per folder; a reply carrying any other token is stale.
    private var loadTokens: [String: Int] = [:]
    private var nextLoadToken = 0

    /// Visited directories, oldest first, with `historyIndex` marking the one
    /// on screen. Kept private so the trail can only be walked through
    /// `navigate`, `goBack`, and `goForward`.
    private var history: [URL] = []
    private var historyIndex = 0

    private static let historyLimit = 128

    init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
        directory = fileSystem.homeDirectory.standardizedFileURL
        history = [directory]
        observeChanges()
    }

    /// The standardized path a folder or row is known by, so a URL from search
    /// or the agent matches a listing's URL with or without a trailing slash.
    nonisolated static func key(_ url: URL) -> String {
        url.standardizedFileURL.path
    }

    func use(fileSystem: any WorkspaceFileSystem, initialDirectory: URL? = nil) {
        // A change stream has one reader, and re-adopting the same workspace
        // keeps its filesystem, so only a new one is subscribed to.
        let isNewFileSystem = fileSystem !== self.fileSystem
        self.fileSystem = fileSystem
        // Paths on the old filesystem mean nothing on the new one, and a new
        // workspace starts a new trail: back must never walk into them.
        expanded = []
        watched = []
        if isNewFileSystem { observeChanges() }
        let target = (initialDirectory ?? fileSystem.homeDirectory).standardizedFileURL
        history = [target]
        historyIndex = 0
        show(target)
    }

    // MARK: Navigation

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

    func goUp() {
        guard canGoUp else { return }
        navigate(to: directory.deletingLastPathComponent())
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

    /// Re-roots the tree at `directory` without touching the trail. Expanded
    /// folders are remembered, so they reopen when they come back into view.
    private func show(_ directory: URL) {
        self.directory = directory
        selectedID = nil
        listings = [:]
        failures = [:]
        loadTokens = [:]
        errorMessage = nil
        load(directory)
    }

    // MARK: Expansion

    /// What double-click and Return do to a folder: open it in place in the
    /// tree, or step into it in the list.
    func activate(_ folder: URL) {
        if layout == .tree {
            setExpanded(folder, !expanded.contains(Self.key(folder)))
        } else {
            navigate(to: folder)
        }
    }

    /// Opening always re-reads the folder, showing any cached listing until the
    /// reply lands.
    func setExpanded(_ folder: URL, _ isExpanded: Bool) {
        let key = Self.key(folder)
        guard expanded.contains(key) != isExpanded else { return }
        if isExpanded {
            expanded.insert(key)
            load(folder)
        } else {
            expanded.remove(key)
            rebuildRows()
        }
    }

    func collapseAll() {
        expanded = []
        rebuildRows()
    }

    var selectedRow: FileTreeRow? {
        rows.first { $0.id == selectedID }
    }

    /// Right arrow. False when there's nothing to open, so the key passes on.
    func expandSelection() -> Bool {
        guard layout == .tree, let row = selectedRow, row.entry.isDirectory, !row.isExpanded else { return false }
        setExpanded(row.entry.url, true)
        return true
    }

    /// Left arrow: closes the highlighted folder, or moves up to its parent row.
    func collapseSelection() -> Bool {
        guard layout == .tree, let row = selectedRow else { return false }
        if row.isExpanded {
            setExpanded(row.entry.url, false)
            return true
        }
        let parent = Self.key(row.entry.url.deletingLastPathComponent())
        guard rows.contains(where: { $0.id == parent }) else { return false }
        selectedID = parent
        return true
    }

    /// Where New File and New Folder write: the highlighted folder (or the
    /// highlighted file's folder) in tree layout, the root otherwise.
    var targetDirectory: URL {
        guard layout == .tree, let entry = selectedRow?.entry else { return directory }
        return entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
    }

    /// Highlights `url`, opening the folders between it and the root in tree layout.
    func reveal(_ url: URL) {
        selectedID = Self.key(url)
        guard layout == .tree else { return }
        let root = directory.pathComponents
        var folder = url.standardizedFileURL.deletingLastPathComponent()
        while folder.pathComponents.count > root.count, folder.pathComponents.starts(with: root) {
            setExpanded(folder, true)
            folder = folder.deletingLastPathComponent()
        }
    }

    /// Shows something just created: re-reads its folder and highlights it.
    func didCreate(_ url: URL) {
        let folder = url.deletingLastPathComponent()
        let key = Self.key(folder)
        // A collapsed folder is read as `reveal` opens it; an open one isn't.
        let isOnScreen = key == Self.key(directory) || expanded.contains(key)
        reveal(url)
        if isOnScreen { load(folder) }
    }

    // MARK: Loading

    /// Re-reads the root and every expanded folder on screen, keeping what's
    /// shown until each reply lands so a refresh never flickers.
    func refresh() {
        let open = rows.filter(\.isExpanded).map(\.entry.url)
        load(directory)
        for folder in open { load(folder) }
    }

    /// Re-reads a watched folder the filesystem reports as changed on disk.
    private func observeChanges() {
        changesTask?.cancel()
        changesTask = Task { [weak self, changes = fileSystem.folderChanges] in
            for await folder in changes {
                guard let self else { return }
                if watched.contains(Self.key(folder)) { load(folder) }
            }
        }
    }

    private func load(_ folder: URL) {
        let key = Self.key(folder)
        nextLoadToken &+= 1
        let token = nextLoadToken
        loadTokens[key] = token
        let isRoot = key == Self.key(directory)
        // The root keeps its old rows until the reply; a subfolder shows its spinner.
        if isRoot { isLoading = true } else { rebuildRows() }
        let fileSystem = fileSystem
        let includesHiddenFiles = showsHiddenFiles

        Task {
            let contents: [Entry]?
            let failure: String?
            do {
                contents = try await fileSystem.contentsOfDirectory(at: folder, includingHiddenFiles: includesHiddenFiles)
                failure = nil
            } catch {
                contents = nil
                failure = error.localizedDescription
            }
            guard loadTokens[key] == token else { return }
            loadTokens[key] = nil
            listings[key] = contents.map { sorted($0) }
            failures[key] = failure
            if isRoot {
                isLoading = false
                errorMessage = failure
            }
            rebuildRows()
            // Folders left expanded from an earlier visit are read as they come
            // back into view.
            guard layout == .tree else { return }
            for entry in contents ?? [] where entry.isDirectory {
                let child = Self.key(entry.url)
                if expanded.contains(child), listings[child] == nil, loadTokens[child] == nil {
                    load(entry.url)
                }
            }
        }
    }

    private func rebuildRows() {
        var rows: [FileTreeRow] = []
        func append(_ folder: String, depth: Int) {
            for entry in listings[folder] ?? [] {
                let key = Self.key(entry.url)
                let isOpen = layout == .tree && entry.isDirectory && expanded.contains(key)
                rows.append(FileTreeRow(
                    entry: entry,
                    depth: depth,
                    isExpanded: isOpen,
                    isLoading: isOpen && loadTokens[key] != nil,
                    failure: isOpen ? failures[key] : nil
                ))
                if isOpen { append(key, depth: depth + 1) }
            }
        }
        append(Self.key(directory), depth: 0)
        self.rows = rows
        let folders = Set([Self.key(directory)] + rows.filter(\.isExpanded).map(\.id))
        if folders != watched {
            watched = folders
            fileSystem.watch(folders.map { URL(fileURLWithPath: $0, isDirectory: true) })
        }
    }

    // MARK: Sorting

    private func resort() {
        listings = listings.mapValues { sorted($0) }
        rebuildRows()
    }

    private func sorted(_ entries: [Entry]) -> [Entry] {
        entries.sorted { lhs, rhs in
            if foldersFirst, lhs.isDirectory != rhs.isDirectory { return lhs.isDirectory }
            var order = switch sortKey {
                case .name:
                    ComparisonResult.orderedSame
                case .kind:
                    lhs.url.pathExtension.localizedStandardCompare(rhs.url.pathExtension)
                case .dateModified:
                    Self.compare(lhs.modificationDate ?? .distantPast, rhs.modificationDate ?? .distantPast)
                case .size:
                    // A folder's own size is just its directory record, and only
                    // SSH reports it, so folders sort as empty everywhere.
                    Self.compare(lhs.isDirectory ? -1 : lhs.byteCount ?? -1,
                                 rhs.isDirectory ? -1 : rhs.byteCount ?? -1)
            }
            if order == .orderedSame { order = lhs.label.localizedStandardCompare(rhs.label) }
            return order == (sortsAscending ? .orderedAscending : .orderedDescending)
        }
    }

    private static func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        lhs < rhs ? .orderedAscending : lhs > rhs ? .orderedDescending : .orderedSame
    }
}
