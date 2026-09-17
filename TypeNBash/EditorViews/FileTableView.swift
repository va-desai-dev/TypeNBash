import AppKit
import SwiftUI

/// AppKit `NSTableView` backing for the file list.
///
/// SwiftUI's `List` re-diffs every row and stutters on large directories, while a
/// `LazyVStack` scrolls but has none of a list's semantics (selection, keyboard
/// navigation, cell reuse). `NSTableView` recycles a handful of cell views and
/// never touches the rest, so scroll stays smooth no matter how many entries
/// there are — it's the same control Finder's list view uses.
///
/// The view talks only to `FileBrowserModel`'s vocabulary (`entries`,
/// `selectedFile`, `select(_:)`), so it drops in wherever the SwiftUI list was.
struct FileTableView: NSViewRepresentable {
    var entries: [WorkspaceFileEntry]
    /// The file currently previewed by the model; drives the highlighted row.
    var selection: URL?
    /// Enables app-open / reveal actions in the context menu for local workspaces.
    var isLocal: Bool
    /// Previews a file or navigates into a folder (routes to `model.select`).
    var onSelect: (WorkspaceFileEntry) -> Void
    var onOpenInTerminal: (WorkspaceFileEntry) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tableView = KeyableTableView()
        tableView.headerView = nil
        // Opaque background + layer backing let AppKit use its overdraw buffer for
        // responsive (off-main-thread) scrolling. A clear background forces a
        // synchronous redraw every frame, which reads as scroll jank. `Color.card`
        // is already the pane's solid backdrop, so this changes nothing visually.
        tableView.backgroundColor = NSColor(Color.card)
        tableView.wantsLayer = true
        tableView.style = .automatic
        tableView.rowHeight = 24
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.selectionHighlightStyle = .regular
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = false
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("FileColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        tableView.dataSource = context.coordinator
        tableView.delegate = context.coordinator
        // Single click acts on the clicked row (file → preview, folder → navigate),
        // matching the old Button behaviour. Keyboard selection only highlights;
        // Return opens, so arrowing over a folder never dives into it.
        tableView.target = context.coordinator
        tableView.action = #selector(Coordinator.rowClicked(_:))
        tableView.onActivateRow = { [weak coordinator = context.coordinator] row in
            coordinator?.activateRow(row)
        }

        let menu = NSMenu()
        menu.delegate = context.coordinator
        tableView.menu = menu

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = NSColor(Color.card)
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.verticalScroller?.isHidden = true

        context.coordinator.tableView = tableView
        context.coordinator.entries = entries
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tableView = nsView.documentView as? KeyableTableView else { return }
        if context.coordinator.entries != entries {
            context.coordinator.entries = entries
            tableView.reloadData()
        }
        context.coordinator.syncSelection(to: selection)
    }

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var parent: FileTableView
        var entries: [WorkspaceFileEntry] = []
        weak var tableView: KeyableTableView?

        /// The last selection we pushed to (or observed from) the table. Guards
        /// `syncSelection` so an incidental SwiftUI re-render can't yank the
        /// highlight away from a row the user just arrowed to.
        private var lastSyncedSelection: URL?
        private var isSyncingSelection = false
        /// Entry captured when the context menu is built, used by its actions.
        private var menuEntry: WorkspaceFileEntry?

        private static let cellIdentifier = NSUserInterfaceItemIdentifier("FileCell")

        init(_ parent: FileTableView) {
            self.parent = parent
            self.entries = parent.entries
        }

        // MARK: Data source

        func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let cell = tableView.makeView(withIdentifier: Self.cellIdentifier, owner: self) as? FileCellView
                ?? FileCellView(identifier: Self.cellIdentifier)
            cell.configure(with: entries[row])
            return cell
        }

        // MARK: Selection

        func syncSelection(to url: URL?) {
            guard let tableView, url != lastSyncedSelection else { return }
            lastSyncedSelection = url
            isSyncingSelection = true
            defer { isSyncingSelection = false }
            if let url, let row = entries.firstIndex(where: { $0.url == url }) {
                if tableView.selectedRow != row {
                    tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                }
            } else {
                tableView.deselectAll(nil)
            }
        }

        @objc func rowClicked(_ sender: NSTableView) {
            act(on: sender.clickedRow)
        }

        func activateRow(_ row: Int) {
            act(on: row)
        }

        private func act(on row: Int) {
            guard entries.indices.contains(row) else { return }
            let entry = entries[row]
            // Remember the file we're about to preview so the follow-up
            // `syncSelection` treats the current highlight as already correct.
            lastSyncedSelection = entry.isDirectory ? lastSyncedSelection : entry.url
            parent.onSelect(entry)
        }

        // MARK: Context menu

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let tableView, entries.indices.contains(tableView.clickedRow) else {
                menuEntry = nil
                return
            }
            let entry = entries[tableView.clickedRow]
            menuEntry = entry

            if parent.isLocal, !entry.isDirectory {
                addItem(to: menu, title: "Open in Default App", action: #selector(openInDefaultApp))
            }
            addItem(
                to: menu,
                title: entry.isDirectory ? "Open in Terminal" : "Open Folder in Terminal",
                action: #selector(openInTerminal)
            )
            menu.addItem(.separator())
            addItem(to: menu, title: "Copy Path", action: #selector(copyPath))
            if parent.isLocal {
                addItem(to: menu, title: "Reveal in Finder", action: #selector(revealInFinder))
            }
        }

        private func addItem(to menu: NSMenu, title: String, action: Selector) {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }

        @objc private func openInDefaultApp() {
            guard let entry = menuEntry else { return }
            NSWorkspace.shared.open(entry.url)
        }

        @objc private func openInTerminal() {
            guard let entry = menuEntry else { return }
            parent.onOpenInTerminal(entry)
        }

        @objc private func copyPath() {
            guard let entry = menuEntry else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.url.path, forType: .string)
        }

        @objc private func revealInFinder() {
            guard let entry = menuEntry else { return }
            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
        }
    }
}

/// `NSTableView` that opens the selected row on Return/Enter, so keyboard
/// navigation can highlight rows without acting until the user commits.
final class KeyableTableView: NSTableView {
    var onActivateRow: ((Int) -> Void)?

    override func keyDown(with event: NSEvent) {
        // 36 = Return, 76 = keypad Enter.
        if (event.keyCode == 36 || event.keyCode == 76), selectedRow >= 0 {
            onActivateRow?(selectedRow)
            return
        }
        super.keyDown(with: event)
    }
}

/// Finder-style single-column row: icon, truncating name, and a folder chevron.
private final class FileCellView: NSTableCellView {
    private let icon = NSImageView()
    private let label = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var isDirectory = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier

        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail
        label.cell?.usesSingleLineMode = true
        label.drawsBackground = false
        label.isBordered = false
        label.isEditable = false

        chevron.translatesAutoresizingMaskIntoConstraints = false
        chevron.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)
        chevron.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .regular)
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        addSubview(icon)
        addSubview(label)
        addSubview(chevron)

        // Wiring these outlets lets NSTableCellView adjust the label colour for us
        // when the row's background style changes under selection.
        imageView = icon
        textField = label

        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),

            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            chevron.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 8),
            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    func configure(with entry: WorkspaceFileEntry) {
        isDirectory = entry.isDirectory
        icon.image = NSImage(systemSymbolName: entry.icon, accessibilityDescription: nil)
        label.stringValue = entry.url.lastPathComponent
        chevron.isHidden = !entry.isDirectory
        applyColors()
    }

    private func applyColors() {
        let emphasized = backgroundStyle == .emphasized
        icon.contentTintColor = emphasized
            ? .alternateSelectedControlTextColor
            : (isDirectory ? .controlAccentColor : .secondaryLabelColor)
        chevron.contentTintColor = emphasized
            ? .alternateSelectedControlTextColor
            : .tertiaryLabelColor
    }
}
