import AppKit
import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    /// Declared in Info.plist. Only the file tree reads it, so drags from
    /// other apps never land as moves.
    nonisolated static let fileTreeItem = UTType(exportedAs: "VD.TypeNBash.file-tree-item")
}

/// A row being dragged within a file tree. `source` is the tree it came
/// from, so a drop into another window's tree — whose paths may be another
/// host's — is refused.
nonisolated struct FileTreeDragItem: Codable, Transferable {
    let source: UUID
    let path: String
    let isDirectory: Bool

    var entry: WorkspaceFileEntry {
        WorkspaceFileEntry(url: URL(filePath: path, directoryHint: isDirectory ? .isDirectory : .notDirectory),
                           isDirectory: isDirectory, byteCount: nil)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .fileTreeItem)
    }
}

/// How fast a drag held near the list's top or bottom edge scrolls it. Kept
/// apart from the view so it can be checked without a real drag session.
nonisolated enum FileTreeAutoscroll {
    /// The band inside each edge that scrolls, and how far past the edge the
    /// pointer can stray, over a header or footer, and still scroll at full speed.
    static let edge: CGFloat = 36
    static let overshoot: CGFloat = 40
    /// Points per frame at the edge itself.
    static let maxStep: CGFloat = 16

    /// Points to scroll this frame, given how far the pointer is inside the
    /// list's top and bottom edges: negative is up, positive down, faster
    /// nearer the edge, and nil anywhere else.
    static func step(fromTop top: CGFloat, fromBottom bottom: CGFloat) -> CGFloat? {
        func speed(_ distance: CGFloat) -> CGFloat? {
            guard distance < edge, distance > -overshoot else { return nil }
            let closeness = min((edge - distance) / edge, 1)
            return max(2, maxStep * closeness)
        }
        if let up = speed(top), top <= bottom { return -up }
        if let down = speed(bottom) { return down }
        return nil
    }
}

/// Holds the list's scroll view without keeping it alive. Not observed:
/// nothing on screen changes when it's found.
private final class WeakScrollView {
    weak var view: NSScrollView?
}

/// Finds the AppKit scroll view behind a SwiftUI `List`, which auto-scroll
/// moves directly: SwiftUI reports no row positions as an AppKit list
/// scrolls, so they can't steer it.
struct ScrollViewLocator: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> Probe { Probe(found: found) }
    func updateNSView(_ view: Probe, context: Context) { view.found = found }

    final class Probe: NSView {
        var found: (NSScrollView) -> Void
        init(found: @escaping (NSScrollView) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // The list lays out alongside this background; look once it has.
            DispatchQueue.main.async { [weak self] in self?.locate() }
        }

        /// The innermost scroll view, near this probe, under its centre.
        private func locate() {
            guard window != nil else { return }
            let centre = convert(NSPoint(x: bounds.midX, y: bounds.midY), to: nil)
            var ancestor = superview
            while let view = ancestor {
                let candidates = Self.scrollViews(in: view).filter {
                    $0.convert($0.bounds, to: nil).contains(centre)
                }
                if let match = candidates.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
                    return found(match)
                }
                ancestor = view.superview
            }
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { child -> [NSScrollView] in
                (child as? NSScrollView).map { [$0] } ?? scrollViews(in: child)
            }
        }
    }
}


//MARK: FileBrowser core sidebar tab
/// Finder-style pane beside the console. Works for both the local and SSH
/// Workspace filesystems since it talks only to `FileBrowserModel`.
struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel
    /// Whether the workspace is local (enables app-open / reveal actions).
    var isLocal = true


    /// Requests that the console cd to this entry's directory.
    var onOpenInTerminal: (WorkspaceFileEntry) -> Void = { _ in }
    @State private var pendingDeletion: WorkspaceFileEntry?
    @State private var renaming: WorkspaceFileEntry?
    @State private var newName = ""
    /// A failed delete or rename: its title and message.
    @State private var failure: (title: String, message: String)?


    var body: some View {
        FileBrowserList(
            tree: model.tree,
            isLocal: isLocal,
            deletionIsRecoverable: model.deletionIsRecoverable,
            onOpen: model.select,
            onOpenInTerminal: onOpenInTerminal,
            onRename: { entry in
                newName = entry.label
                renaming = entry
            },
            onMove: { entry, folder in
                Task {
                    if let message = await model.move(entry, into: folder) { failure = ("Couldn’t Move", message) }
                }
            },
            onDelete: { pendingDeletion = $0 }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .overlay { listOverlay }
        // Always confirmed, even for the Trash: a folder takes everything in it.
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { entry in
            Button(model.deletionIsRecoverable ? "Move to Trash" : "Delete", role: .destructive) {
                Task {
                    if let message = await model.delete(entry) { failure = ("Couldn’t Delete", message) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text(deletionMessage(for: entry))
        }
        .alert("Rename", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        ), presenting: renaming) { entry in
            TextField("Name", text: $newName)
            Button("Rename") {
                let name = newName
                Task {
                    if let message = await model.rename(entry, to: name) { failure = ("Couldn’t Rename", message) }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: { entry in
            Text("Enter a new name for “\(entry.label)”.")
        }
        .alert(failure?.title ?? "", isPresented: Binding(
            get: { failure != nil }, set: { if !$0 { failure = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(failure?.message ?? "")
        }
    }

    private var deletionTitle: String {
        guard let entry = pendingDeletion else { return "" }
        return model.deletionIsRecoverable
            ? "Move “\(entry.label)” to the Trash?"
            : "Permanently delete “\(entry.label)”?"
    }

    private func deletionMessage(for entry: WorkspaceFileEntry) -> String {
        let what = entry.isDirectory ? "This folder and everything in it" : "This file"
        var message = model.deletionIsRecoverable
            ? "\(what) can be restored from the Trash."
            : "\(what) will be deleted from the remote host. This can’t be undone."
        if model.deletionDiscardsEdits(entry.url) {
            message += " The open file’s unsaved edits will be lost."
        }
        return message
    }

    @ViewBuilder var listOverlay: some View {
        if let error = model.tree.errorMessage {
            ContentUnavailableView(
                "Folder Unavailable",
                systemImage: "folder.badge.questionmark",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if model.tree.rows.isEmpty && model.tree.filterMatches != nil {
            ContentUnavailableView.search(text: model.tree.filter)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if model.tree.rows.isEmpty && !model.tree.isLoading {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

//MARK: Filebrowser/row primitive component TO BE REUSED
struct FileListRow<Tag: Hashable, LeadingItem: View, TrailingItem: View>: View {

    let filename: String
    let icon: FileTypeIcon
    let style: Color
    let tag: Tag
    let leadingItem: LeadingItem
    let trailingItem: TrailingItem

    init(
        filename: String,
        icon: FileTypeIcon,
        style: Color,
        tag: Tag,
        @ViewBuilder leadingItem: () -> LeadingItem = { EmptyView() },
        @ViewBuilder trailingItem: () -> TrailingItem
    ) {
        self.filename = filename
        self.icon = icon
        self.style = style
        self.tag = tag
        self.leadingItem = leadingItem()
        self.trailingItem = trailingItem()
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingItem
            FileTypeIconView(icon: icon, symbolStyle: style)
            Text(filename)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            trailingItem
        }
        .frame(height: 20)
        .contentShape(Rectangle())
        .tag(tag)
    }
}

//MARK: FileTree ListView
/// The browser's rows, flat or as a tree. Every decision about what a click or
/// key does lives in `FileTreeModel`; this only draws rows and forwards input.
struct FileBrowserList: View {
    @Bindable var tree: FileTreeModel
    let isLocal: Bool
    /// Names the delete command: to the Trash locally, permanent over SSH.
    let deletionIsRecoverable: Bool
    let onOpen: (WorkspaceFileEntry) -> Void
    let onOpenInTerminal: (WorkspaceFileEntry) -> Void
    /// Asks for a new name; the caller prompts for it.
    let onRename: (WorkspaceFileEntry) -> Void
    /// Moves a dragged entry into a folder.
    let onMove: (WorkspaceFileEntry, URL) -> Void
    /// Asks to delete; the caller confirms first.
    let onDelete: (WorkspaceFileEntry) -> Void
    /// The row id a drag is over, or the root's key over empty space.
    @State private var dropTarget: String?
    /// The scroll view behind the list, found once it's on screen.
    @State private var scrollView = WeakScrollView()
    @State private var autoscrollTask: Task<Void, Never>?

    var body: some View {
        List(selection: $tree.selectedID) {
            ForEach(tree.rows) { row in
                let entry = row.entry
                FileListRow(
                    filename: entry.label,
                    icon: entry.icon,
                    style: entry.isDirectory ? Color.accentColor : Color.secondary,
                    tag: row.id,
                    leadingItem: {
                        if tree.layout == .tree { disclosure(for: row) }
                    },
                    trailingItem: { status(of: row) }
                )
                .padding(.leading, CGFloat(row.depth) * 14)
                .draggable(FileTreeDragItem(source: tree.dragSourceID, path: entry.url.path,
                                            isDirectory: entry.isDirectory)) {
                    Label(entry.label, systemImage: entry.isDirectory ? "folder" : "doc")
                }
                // A folder takes the drop; a file passes it to the folder it's in.
                .dropDestination(for: FileTreeDragItem.self) { items, _ in
                    drop(items, into: entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent())
                } isTargeted: { isOver in
                    target(row.id, isOver)
                }
                .onTapGesture(count: 1) {
                    tree.selectedID = row.id
                }
                .onTapGesture(count: 2) {
                    onOpen(entry)
                }
                .listRowBackground(
                    dropTarget == row.id ? Color(NSColor.controlAccentColor).opacity(0.38) : Color.clear
                )
                .contextMenu {
                    if isLocal && !entry.isDirectory {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(entry.url)
                        }
                    }
                    if entry.isDirectory {
                        if tree.layout == .tree {
                            Button("Open as Root", systemImage: "folder") {
                                tree.navigate(to: entry.url)
                            }
                        }
                        Button(entry.isDirectory ? "Open in Terminal" : "Open Folder in Terminal",
                               systemImage: "terminal") {
                            onOpenInTerminal(entry)
                        }
                    }
                    Divider()
                    Button("Copy Path", systemImage: "document.on.document") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url.path, forType: .string)
                    }
                    if isLocal {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
                    Divider()
                    Button("Rename…", systemImage: "pencil") {
                        onRename(entry)
                    }
                    Button(deletionIsRecoverable ? "Move to Trash…" : "Delete Permanently…",
                           systemImage: "trash", role: .destructive) {
                        onDelete(entry)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        .background(ScrollViewLocator { scrollView.view = $0 })
        
        // Empty space below the rows is the folder being browsed.
        .dropDestination(for: FileTreeDragItem.self) { items, _ in
            drop(items, into: tree.directory)
        } isTargeted: { isOver in
            target(FileTreeModel.key(tree.directory), isOver)
        }
        .onDisappear { autoscrollTask?.cancel() }
        .onKeyPress(.return) {
            guard let entry = tree.selectedRow?.entry else { return .ignored }
            onOpen(entry)
            return .handled
        }
        .onKeyPress(.rightArrow) { tree.expandSelection() ? .handled : .ignored }
        .onKeyPress(.leftArrow) { tree.collapseSelection() ? .handled : .ignored }
        // ⌘⌫, as in Finder; it still asks first.
        .onKeyPress(keys: [.delete]) { press in
            guard press.modifiers == .command, let entry = tree.selectedRow?.entry else { return .ignored }
            onDelete(entry)
            return .handled
        }
    }

    /// Only drags from this tree count; each item moves on its own.
    private func drop(_ items: [FileTreeDragItem], into folder: URL) -> Bool {
        dropTarget = nil
        let mine = items.filter { $0.source == tree.dragSourceID }
        for item in mine { onMove(item.entry, folder) }
        return !mine.isEmpty
    }

    /// Highlights what a drag is over. The first drag over the list starts
    /// auto-scroll, which runs until the mouse button comes up.
    private func target(_ id: String, _ isOver: Bool) {
        if isOver {
            dropTarget = id
            startAutoscroll()
        } else if dropTarget == id {
            dropTarget = nil
        }
    }

    /// Polls the pointer each frame while a drag is under way and, when it
    /// rests near the list's top or bottom edge, scrolls the AppKit scroll
    /// view by a few points — the way Finder and table views do — so the
    /// rows under the drag stay what AppKit says they are.
    private func startAutoscroll() {
        guard autoscrollTask == nil else { return }
        autoscrollTask = Task { @MainActor in
            defer { autoscrollTask = nil }
            while !Task.isCancelled, NSEvent.pressedMouseButtons & 1 != 0 {
                if let view = scrollView.view, let window = view.window {
                    scroll(view, pointer: window.convertPoint(fromScreen: NSEvent.mouseLocation))
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func scroll(_ scrollView: NSScrollView, pointer: NSPoint) {
        // Window coordinates run upward; insets are the header and footer bars
        // the list scrolls beneath.
        let frame = scrollView.convert(scrollView.bounds, to: nil)
        guard frame.minX <= pointer.x, pointer.x <= frame.maxX else { return }
        let insets = scrollView.contentInsets
        guard let step = FileTreeAutoscroll.step(fromTop: frame.maxY - insets.top - pointer.y,
                                                 fromBottom: pointer.y - (frame.minY + insets.bottom)) else { return }
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.y += clip.isFlipped ? step : -step
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size))
        guard constrained.origin != clip.bounds.origin else { return }
        clip.scroll(to: constrained.origin)
        scrollView.reflectScrolledClipView(clip)
    }

    /// Files get the same width empty, so names line up at every depth.
    private func disclosure(for row: FileTreeRow) -> some View {
        Button {
            tree.setExpanded(row.entry.url, !row.isExpanded)
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.entry.isDirectory ? 1 : 0)
        .disabled(!row.entry.isDirectory)
        .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder private func status(of row: FileTreeRow) -> some View {
        if row.isLoading {
            ProgressView().controlSize(.mini)
        } else if let failure = row.failure {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(failure)
        } else if tree.layout == .list && row.entry.isDirectory {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
