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

/// The local filesystem, except that deletion removes outright so the
/// checks never fill the user's Trash.
@MainActor
private final class NoTrashFileSystem: WorkspaceFileSystem {
    let local = LocalWorkspaceFileSystem()
    let homeDirectory: URL
    var deleted: [URL] = []
    init(home: URL) { homeDirectory = home }

    func contentsOfDirectory(at url: URL, includingHiddenFiles: Bool) async throws -> [WorkspaceFileEntry] {
        try await local.contentsOfDirectory(at: url, includingHiddenFiles: includingHiddenFiles)
    }
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        try await local.readFile(at: url, maximumByteCount: maximumByteCount)
    }
    func writeFile(_ data: Data, to url: URL) async throws { try await local.writeFile(data, to: url) }
    func createDirectory(at url: URL) async throws { try await local.createDirectory(at: url) }
    func deleteItem(at url: URL) async throws {
        deleted.append(url)
        try FileManager.default.removeItem(at: url)
    }
    func moveItem(at url: URL, to destination: URL) async throws {
        try await local.moveItem(at: url, to: destination)
    }
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

    @MainActor static func autoscrollChecks() async throws {
        typealias Autoscroll = FileTreeAutoscroll
        let edge = Autoscroll.edge
        check(Autoscroll.step(fromTop: 200, fromBottom: 200) == nil, "Away from the edges, a drag doesn't scroll")
        let up = Autoscroll.step(fromTop: 2, fromBottom: 300), down = Autoscroll.step(fromTop: 300, fromBottom: 2)
        check((up ?? 0) < 0 && (down ?? 0) > 0, "Near the top it scrolls up; near the bottom, down")
        check(abs(Autoscroll.step(fromTop: 0, fromBottom: 300)!) > abs(Autoscroll.step(fromTop: edge - 4, fromBottom: 300)!),
              "Nearer the edge scrolls faster")
        check(Autoscroll.step(fromTop: -20, fromBottom: 300) == -Autoscroll.maxStep
              && Autoscroll.step(fromTop: -(Autoscroll.overshoot + 5), fromBottom: 300) == nil,
              "Just past the edge, over a header, still scrolls at full speed; far past it doesn't")

        // The locator must find the List's own scroll view, not a neighbour's.
        var found: NSScrollView?
        let host = NSHostingView(rootView: HStack(spacing: 0) {
            ScrollView { VStack { ForEach(0..<100, id: \.self) { Text("other \($0)") } } }.frame(width: 150)
            List(0..<200, id: \.self) { Text("row \($0)") }
                .background(ScrollViewLocator { found = $0 })
                .frame(width: 200)
        }.frame(width: 350, height: 300))
        let window = NSWindow(contentRect: NSRect(x: 60, y: 60, width: 350, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        defer { window.close() }
        await until("scroll view located") { found != nil }
        check(found?.documentView is NSTableView, "The locator finds the List's scroll view, not its neighbour's")

        // Moving its clip view, as auto-scroll does, scrolls the List.
        let clip = found!.contentView
        let before = clip.bounds.origin.y
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? 120 : -120
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin)
        found!.reflectScrolledClipView(clip)
        check(abs(clip.bounds.origin.y - before) > 100, "Moving the clip view scrolls the List")
        let far = clip.constrainBoundsRect(NSRect(origin: NSPoint(x: 0, y: clip.isFlipped ? 1e6 : -1e6), size: clip.bounds.size))
        check(far.maxY <= (found!.documentView?.frame.maxY ?? 0) + 1, "Scrolling stops at the end of the list")
    }

    @MainActor static func renameChecks(root: URL) async throws {
        let manager = FileManager.default
        let project = root.appendingPathComponent("rename-project", isDirectory: true)
        let folder = project.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let open = folder.appendingPathComponent("inner/open.txt")
        let other = project.appendingPathComponent("other.txt")
        try Data("open".utf8).write(to: open)
        try Data("other".utf8).write(to: other)
        let model = FileBrowserModel(fileSystem: NoTrashFileSystem(home: root))
        let tree = model.tree
        tree.layout = .list
        tree.navigate(to: project)
        await until("rename project listing") { tree.rows.count == 2 }
        func entry(_ name: String) -> WorkspaceFileEntry? { tree.rows.first { $0.entry.label == name }?.entry }

        let browsed = WorkspaceFileEntry(url: project, isDirectory: true, byteCount: nil)
        check(await model.rename(browsed, to: "moved") != nil && manager.fileExists(atPath: project.path),
              "The folder being browsed can't be renamed")
        let slashed = await model.rename(entry("other.txt")!, to: "a/b")
        let blank = await model.rename(entry("other.txt")!, to: " ")
        check(slashed != nil && blank != nil, "Names with “/” or nothing in them are refused")
        check(await model.rename(entry("other.txt")!, to: "folder") != nil && manager.fileExists(atPath: other.path),
              "A rename never replaces an existing item")
        check(await model.rename(entry("other.txt")!, to: "other.txt") == nil && manager.fileExists(atPath: other.path),
              "Keeping the same name does nothing")

        // The open file, edited and unsaved, follows its folder's rename.
        model.select(WorkspaceFileEntry(url: open, isDirectory: false, byteCount: 4))
        await until("rename open file loaded") { model.savedPreviewText == "open" }
        model.updatePreviewText("edited")
        check(await model.rename(entry("folder")!, to: "renamed") == nil, "A folder renames")
        let moved = project.appendingPathComponent("renamed/inner/open.txt")
        check(manager.fileExists(atPath: moved.path) && !manager.fileExists(atPath: folder.path), "The folder moved on disk")
        check(model.selectedFile?.standardizedFileURL.path == moved.standardizedFileURL.path
              && model.hasUnsavedChanges && model.savedPreviewText == "open",
              "The open file follows with its unsaved edits")
        check(tree.rows.map(\.entry.label).contains("renamed") && !tree.rows.map(\.entry.label).contains("folder"),
              "The tree shows the new name at once")
        await until("renamed parent re-read") { !tree.isLoading }
        check(tree.selectedRow?.entry.label == "renamed", "The renamed row is selected")

        let caseOnly = await model.rename(entry("other.txt")!, to: "OTHER.txt")
        let names = try manager.contentsOfDirectory(atPath: project.path)
        check(caseOnly == nil && names.contains("OTHER.txt"), "A case-only rename works on a case-insensitive disk")
    }

    @MainActor static func moveChecks(root: URL) async throws {
        let manager = FileManager.default
        let project = root.appendingPathComponent("move-project", isDirectory: true)
        let source = project.appendingPathComponent("source", isDirectory: true)
        let target = project.appendingPathComponent("target", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let open = source.appendingPathComponent("open.txt")
        let loose = project.appendingPathComponent("loose.txt")
        try Data("open".utf8).write(to: open)
        try Data("loose".utf8).write(to: loose)
        let model = FileBrowserModel(fileSystem: NoTrashFileSystem(home: root))
        let tree = model.tree
        tree.layout = .tree
        tree.navigate(to: project)
        await until("move project listing") { tree.rows.count == 3 }
        tree.setExpanded(target, true)
        await until("target listed") {
            tree.rows.first { $0.entry.label == "target" }.map { $0.isExpanded && !$0.isLoading } == true && !tree.isLoading
        }
        func entry(_ name: String) -> WorkspaceFileEntry? { tree.rows.first { $0.entry.label == name }?.entry }
        func labels() -> [String] { tree.rows.map(\.entry.label) }

        check(await model.move(entry("loose.txt")!, into: project) == nil && manager.fileExists(atPath: loose.path),
              "Dropping where an item already is does nothing")
        check(await model.move(entry("loose.txt")!, into: target) == nil, "A file moves into a folder")
        check(manager.fileExists(atPath: target.appendingPathComponent("loose.txt").path) && !manager.fileExists(atPath: loose.path),
              "The file moved on disk")
        check(labels() == ["source", "target", "loose.txt"] && tree.rows[2].depth == 1
              && tree.selectedRow?.entry.label == "loose.txt",
              "It shows inside the open folder at once and is selected")

        let sourceEntry = entry("source")!
        let intoItself = await model.move(sourceEntry, into: source)
        let belowItself = await model.move(sourceEntry, into: source.appendingPathComponent("deeper"))
        check(intoItself != nil && belowItself != nil, "A folder can't move into itself or below itself")

        model.select(WorkspaceFileEntry(url: open, isDirectory: false, byteCount: 4))
        await until("move open file loaded") { model.savedPreviewText == "open" }
        model.updatePreviewText("edited")
        check(await model.move(sourceEntry, into: target) == nil, "A folder moves into another folder")
        let moved = target.appendingPathComponent("source/open.txt")
        check(model.selectedFile?.standardizedFileURL.path == moved.standardizedFileURL.path
              && model.hasUnsavedChanges && model.savedPreviewText == "open",
              "The open file follows its folder with its unsaved edits")
        await until("move parents re-read") { !tree.isLoading }
        // Folders first, as the suite sorts them; the moved folder starts collapsed.
        check(labels() == ["target", "source", "loose.txt"] && tree.rows.dropFirst().allSatisfy { $0.depth == 1 },
              "Both folders show the result: \(labels())")

        try Data("again".utf8).write(to: loose)
        await until("new loose file listed") {
            tree.refresh()
            return labels().filter { $0 == "loose.txt" }.count == 2
        }
        let rootLoose = tree.rows.first { $0.entry.label == "loose.txt" && $0.depth == 0 }!.entry
        check(await model.move(rootLoose, into: target) != nil
              && (try? String(contentsOf: target.appendingPathComponent("loose.txt"), encoding: .utf8)) == "loose"
              && manager.fileExists(atPath: loose.path),
              "A move never replaces an item with the same name")
    }

    @MainActor static func deletionChecks(root: URL) async throws {
        let manager = FileManager.default
        let project = root.appendingPathComponent("delete-project", isDirectory: true)
        let folder = project.appendingPathComponent("folder", isDirectory: true)
        try manager.createDirectory(at: folder.appendingPathComponent("inner"), withIntermediateDirectories: true)
        let open = folder.appendingPathComponent("inner/open.txt")
        let loose = project.appendingPathComponent("loose.txt")
        try Data("open".utf8).write(to: open)
        try Data("loose".utf8).write(to: loose)
        let fileSystem = NoTrashFileSystem(home: root)
        let model = FileBrowserModel(fileSystem: fileSystem)
        let tree = model.tree
        tree.layout = .tree
        tree.navigate(to: project)
        await until("delete project listing") { tree.rows.count == 2 }
        tree.setExpanded(folder, true)
        await until("expanded folder") { tree.rows.count == 3 }
        func row(_ url: URL) -> WorkspaceFileEntry? { tree.rows.first { $0.entry.url.standardizedFileURL == url.standardizedFileURL }?.entry }
        check(!model.deletionIsRecoverable, "A filesystem without a Trash says deletion is permanent")

        // Refusals touch nothing.
        let browsed = WorkspaceFileEntry(url: project, isDirectory: true, byteCount: nil)
        check(await model.delete(browsed) != nil && fileSystem.deleted.isEmpty, "The folder being browsed can't be deleted")
        let home = WorkspaceFileEntry(url: root, isDirectory: true, byteCount: nil)
        check(await model.delete(home) != nil && fileSystem.deleted.isEmpty, "The home folder and its ancestors can't be deleted")

        // Deleting the folder holding the open file closes it, and the rows go at once.
        model.select(WorkspaceFileEntry(url: open, isDirectory: false, byteCount: 4))
        await until("open file loaded") { model.savedPreviewText == "open" }
        check(!model.deletionDiscardsEdits(folder), "A saved open file has no edits to lose")
        model.updatePreviewText("edited")
        check(model.deletionDiscardsEdits(folder) && !model.deletionDiscardsEdits(loose),
              "Only deleting the open file, or a folder holding it, would lose its edits")
        tree.selectedID = FileTreeModel.key(open)
        check(await model.delete(row(folder)!) == nil, "A folder deletes")
        check(!manager.fileExists(atPath: folder.path) && manager.fileExists(atPath: loose.path), "Only that folder is removed")
        let closed = if case .none = model.preview { true } else { false }
        check(model.selectedFile == nil && closed && !model.hasUnsavedChanges,
              "The open file inside it is closed")
        check(tree.rows.map(\.entry.label) == ["loose.txt"] && tree.selectedID == nil,
              "Its rows, children and selection leave the tree")
        await until("parent re-read") { !tree.isLoading }
        check(tree.rows.map(\.entry.label) == ["loose.txt"], "The re-read parent agrees")

        let missing = WorkspaceFileEntry(url: project.appendingPathComponent("missing.txt"), isDirectory: false, byteCount: nil)
        check(await model.delete(missing) != nil && tree.rows.count == 1, "A failed delete reports its error and keeps the rows")
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

        // The footer filter searches the whole tree, not just what's expanded.
        tree.filter = "MAIN"
        await until("filtered") { names() == ["Sources", "App", "main.swift"] }
        check(tree.rows.map(\.depth) == [0, 1, 2] && tree.rows.prefix(2).allSatisfy(\.isExpanded),
              "Filtering finds collapsed matches, ignoring case, under their open folders")
        tree.layout = .list
        check(names() == ["main.swift"], "A filtered list shows the matches alone")
        tree.layout = .tree
        tree.filter = "zzz"
        await until("no matches") { tree.filterMatches?.isEmpty == true && tree.rows.isEmpty }
        check(!tree.isSearchingFiles, "A filter without matches empties the rows")
        tree.filter = "app"
        await until("folder match") { names() == ["Sources", "App"] }
        tree.activate(tree.rows[1].entry.url)
        await until("revealed folder") { names().contains("main.swift") }
        check(tree.filter.isEmpty && tree.selectedRow?.entry.label == "App",
              "Opening a matched folder ends the filter and reveals it in the tree")
        tree.collapseAll()
        model.select(WorkspaceFileEntry(url: deep, isDirectory: false, byteCount: nil))
        await until("revealed") { names().contains("main.swift") }
        check(tree.selectedRow?.entry.label == "main.swift", "Opening a file from elsewhere reveals it in the tree")

        tree.navigate(to: root.appendingPathComponent("Sources"))
        await until("re-rooted") {
            !tree.isLoading && tree.rows.first?.entry.label == "App" && names().contains("main.swift")
        }
        check(tree.rows.first?.depth == 0 && tree.rows.first?.isExpanded == true,
              "Re-rooting reopens remembered folders at their new depth")

        let host = NSHostingView(rootView: WorkspaceSidebar(model: model, isLocal: true, onOpenInTerminal: { _ in }, showsSearch: false, action: {})
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
        try await autoscrollChecks()
        try await renameChecks(root: root)
        try await moveChecks(root: root)
        try await deletionChecks(root: root)
        print("File tree checks passed")
    }
}
