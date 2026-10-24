import AppKit
import SwiftUI
@testable import TypeNBash

/// Holds every listing until the check releases it, so replies can be made to
/// land out of order.
@MainActor
private final class GatedFileSystem: WorkspaceFileSystem {
    let homeDirectory = URL(filePath: "/remote")
    var pending: [(path: String, resume: CheckedContinuation<[WorkspaceFileEntry], Error>)] = []
    let (folderChanges, changes) = AsyncStream<URL>.makeStream()
    var watched: [String] = []

    func watch(_ folders: [URL]) { watched = folders.map(\.path).sorted() }

    func contentsOfDirectory(at url: URL, includingHiddenFiles: Bool) async throws -> [WorkspaceFileEntry] {
        try await withCheckedThrowingContinuation { pending.append((url.path, $0)) }
    }
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data { Data() }
    func writeFile(_ data: Data, to url: URL) async throws {}
    func createDirectory(at url: URL) async throws {}
}

@main
struct FileTreeIntegrationChecks {
    @MainActor static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        AppDefaults.register()
        Task { @MainActor in
            do { try await run(); exit(0) }
            catch { fatalError("File tree check failed: \(error)") }
        }
        NSApp.run()
    }

    @MainActor static func check(_ condition: Bool, _ message: String) {
        precondition(condition, message)
        print("PASS: \(message)")
    }

    @MainActor static func until(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<300 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Timed out waiting for: \(message)")
    }

    @MainActor static func run() async throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("file-tree-\(UUID())")
        defer { try? manager.removeItem(at: root) }
        let nested = root.appendingPathComponent("Sources/App", isDirectory: true)
        try manager.createDirectory(at: nested, withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("docs"), withIntermediateDirectories: true)
        let small = root.appendingPathComponent("b.md")
        let large = root.appendingPathComponent("a.txt")
        let deep = nested.appendingPathComponent("main.swift")
        try Data("1".utf8).write(to: small)
        try Data(repeating: 65, count: 4_096).write(to: large)
        try Data("print()".utf8).write(to: deep)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: large.path)
        try manager.setAttributes([.modificationDate: Date(timeIntervalSince1970: 9_000)], ofItemAtPath: small.path)

        let model = FileBrowserModel()
        let tree = model.tree
        tree.layout = .list
        tree.sortKey = .name
        tree.sortsAscending = true
        tree.foldersFirst = true
        func names() -> [String] { tree.rows.map(\.entry.label) }

        tree.navigate(to: root)
        await until("root listing") { tree.rows.count == 4 }
        check(names() == ["docs", "Sources", "a.txt", "b.md"], "Folders first, then names in Finder order")
        check(tree.rows[1].entry.modificationDate != nil, "Local listings report modification dates")

        tree.sortKey = .dateModified
        tree.sortsAscending = false
        check(names().suffix(2) == ["b.md", "a.txt"], "Date sort reorders cached rows without a reload")
        tree.sortKey = .size
        check(names().suffix(2) == ["a.txt", "b.md"], "Size sort puts the larger file first when descending")
        tree.foldersFirst = false
        tree.sortKey = .name
        tree.sortsAscending = true
        check(names() == ["a.txt", "b.md", "docs", "Sources"], "Folders mix with files when not kept on top")
        tree.foldersFirst = true

        // List layout steps into a folder; the open file and its draft stay put.
        model.select(WorkspaceFileEntry(url: small, isDirectory: false, byteCount: 1))
        await until("preview") { model.searchText == "1" }
        model.updatePreviewText("draft")
        let sources = tree.rows.first { $0.entry.label == "Sources" }!.entry
        model.select(sources)
        await until("child listing") { tree.directory.lastPathComponent == "Sources" && names() == ["App"] }
        check(model.selectedFile == small && model.hasUnsavedChanges, "Browsing away keeps the open file and its draft")
        tree.goBack()
        await until("back") { tree.rows.count == 4 }

        // Tree layout expands in place.
        tree.layout = .tree
        model.select(tree.rows.first { $0.entry.label == "Sources" }!.entry)
        await until("expanded Sources") { names().contains("App") }
        check(tree.directory.standardizedFileURL == root.standardizedFileURL,
              "Activating a folder in tree layout expands it instead of navigating")
        let app = tree.rows.first { $0.entry.label == "App" }!
        check(app.depth == 1 && !app.isExpanded, "Children sit one level deeper, collapsed")

        tree.selectedID = app.id
        check(tree.expandSelection(), "Right arrow opens the highlighted folder")
        await until("expanded App") { names().contains("main.swift") }
        tree.selectedID = tree.rows.first { $0.entry.label == "main.swift" }!.id
        check(tree.targetDirectory.standardizedFileURL == nested.standardizedFileURL,
              "New items go to the highlighted file's folder")
        check(await model.newFolder(named: "Views") == nil, "New Folder succeeds in a nested folder")
        await until("new folder row") { names().contains("Views") }
        check(manager.fileExists(atPath: nested.appendingPathComponent("Views").path), "The folder is created on disk where the tree pointed")
        check(tree.selectedRow?.entry.label == "Views", "The new folder becomes the highlighted row")

        check(tree.collapseSelection() && tree.selectedRow?.entry.label == "App",
              "Left arrow on a collapsed row moves to its parent")
        check(tree.collapseSelection() && !names().contains("main.swift"), "Left arrow then collapses the parent")

        tree.collapseAll()
        check(names() == ["docs", "Sources", "a.txt", "b.md"], "Collapse All returns to the root's own rows")
        model.select(WorkspaceFileEntry(url: deep, isDirectory: false, byteCount: nil))
        await until("revealed") { names().contains("main.swift") }
        check(tree.selectedRow?.entry.label == "main.swift", "Opening a file from elsewhere reveals it in the tree")

        tree.navigate(to: root.appendingPathComponent("Sources"))
        await until("re-rooted") {
            !tree.isLoading && tree.rows.first?.entry.label == "App" && names().contains("main.swift")
        }
        check(tree.rows.first?.depth == 0 && tree.rows.first?.isExpanded == true,
              "Re-rooting reopens remembered folders at their new depth")

        let host = NSHostingView(rootView: WorkspaceSidebar(model: model, isLocal: true, onOpenInTerminal: { _ in })
            .frame(width: 300, height: 360))
        let window = NSWindow(contentRect: NSRect(x: 40, y: 40, width: 300, height: 360),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        tree.selectedID = tree.rows.first { $0.entry.label == "main.swift" }?.id
        try? await Task.sleep(for: .milliseconds(400))
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/centcom-file-tree.png"))
        }
        window.close()

        // A slow reply must not overwrite a newer one for the same folder.
        let gated = GatedFileSystem()
        let remote = FileTreeModel(fileSystem: gated)
        remote.refresh()
        remote.refresh()
        await until("two requests") { gated.pending.count == 2 }
        let home = gated.homeDirectory
        gated.pending[1].resume.resume(returning: [WorkspaceFileEntry(url: home.appendingPathComponent("new"), isDirectory: false, byteCount: nil)])
        await until("new reply") { remote.rows.count == 1 }
        gated.pending[0].resume.resume(returning: [])
        try? await Task.sleep(for: .milliseconds(50))
        check(remote.rows.map(\.entry.label) == ["new"] && !remote.isLoading, "A stale listing reply is discarded")

        // A change pushed for a watched folder re-reads it; others are ignored.
        let folder = home.appendingPathComponent("folder", isDirectory: true)
        check(gated.watched == ["/remote"], "The root is watched once listed")
        gated.changes.yield(home)
        await until("change re-read") { gated.pending.count == 3 }
        gated.pending[2].resume.resume(returning: [WorkspaceFileEntry(url: folder, isDirectory: true, byteCount: nil),
                                                  WorkspaceFileEntry(url: home.appendingPathComponent("new"), isDirectory: false, byteCount: nil)])
        await until("changed rows") { remote.rows.count == 2 }
        check(!remote.isLoading, "A changed root is re-read")
        remote.layout = .tree
        await until("relisted root") { gated.pending.count == 4 }
        gated.pending[3].resume.resume(returning: [WorkspaceFileEntry(url: folder, isDirectory: true, byteCount: nil)])
        remote.setExpanded(folder, true)
        await until("folder listing") { gated.pending.count == 5 }
        gated.pending[4].resume.resume(returning: [])
        await until("expanded watch") { gated.watched == ["/remote", "/remote/folder"] }
        gated.changes.yield(home.appendingPathComponent("elsewhere", isDirectory: true))
        gated.changes.yield(folder)
        await until("folder re-read") { gated.pending.count == 6 }
        check(gated.pending[5].path == folder.path, "Expanded folders are watched and re-read; unwatched ones are not")
        gated.pending[5].resume.resume(returning: [])
        remote.setExpanded(folder, false)
        check(gated.watched == ["/remote"], "Collapsing a folder stops watching it")

        gated.pending.removeAll()
        remote.use(fileSystem: gated, initialDirectory: home)
        await until("reconnect request") { gated.pending.count == 1 }
        gated.pending[0].resume.resume(throwing: CocoaError(.fileReadNoPermission))
        await until("failure") { remote.errorMessage != nil }
        check(remote.rows.isEmpty && !remote.isLoading, "A failed root listing reports its error")

        tree.layout = .list
        print("File tree checks passed")
    }
}
