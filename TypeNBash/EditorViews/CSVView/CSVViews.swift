import SwiftUI
import AppKit

/// A custom-drawn spreadsheet grid.
///
/// Unlike `NSTableView`, this does NOT create a view (or column object) per cell.
/// It draws only the cells intersecting the exposed rect with Core Text, so the
/// per-frame cost scales with *visible* cells and is flat in total column count —
/// which is what keeps vertical scroll smooth across 182 columns.
struct FastCSVTableView: NSViewRepresentable {
    let storage: CSVStorage
    @Binding var refreshTrigger: Bool
    /// Called after a cell edit changes a value. The grid mutates `storage`
    /// directly, so this is the only signal SwiftUI gets that the data is dirty.
    var onEdit: (() -> Void)?

    func makeNSView(context: Context) -> CSVTableContainerView {
        let container = CSVTableContainerView()
        container.storage = storage
        container.onEdit = onEdit
        container.setUp()
        return container
    }

    func updateNSView(_ nsView: CSVTableContainerView, context: Context) {
        nsView.storage = storage
        nsView.onEdit = onEdit
        nsView.reload()
    }
}

/// The tabular preview for a `.csv` selected in the file browser.
///
/// Bridges the two shapes the data has to take: `FileBrowserModel` holds a
/// `CSVTable` value because it parses previews off the main actor, while the
/// grid needs a `CSVStorage` reference it can edit cell by cell. The storage is
/// built once — the caller keys this view by file URL, so a new file makes a new
/// view rather than refilling this one — and from then on the grid owns the
/// cells, pushing a snapshot back to the model after each committed edit.
struct CSVPreviewView: View {
    let table: CSVTable
    let onEdit: (CSVTable) -> Void

    @State private var storage: CSVStorage
    @State private var refreshTrigger = false

    init(table: CSVTable, onEdit: @escaping (CSVTable) -> Void) {
        self.table = table
        self.onEdit = onEdit
        _storage = State(initialValue: CSVStorage(table))
    }

    var body: some View {
        FastCSVTableView(storage: storage, refreshTrigger: $refreshTrigger) {
            onEdit(storage.table)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Container (frozen header + scrollable body)

final class CSVTableContainerView: NSView {
    static let rowHeight: CGFloat = 22
    static let columnWidth: CGFloat = 150
    static let headerHeight: CGFloat = 26

    var storage: CSVStorage = .empty
    var onEdit: (() -> Void)?

    private let scrollView = NSScrollView()
    private let bodyView = CSVGridBodyView()
    private let headerView = CSVHeaderView()

    func setUp() {
        headerView.container = self
        bodyView.container = self

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.documentView = bodyView

        // Treat Force Touch as an ordinary click so double-click-to-edit doesn't
        // fight the trackpad's deep-press (force-click) second stage.
        bodyView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryClick)

        addSubview(scrollView)
        addSubview(headerView)

        // Keep the frozen header aligned with the body's horizontal scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bodyDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        reload()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func bodyDidScroll() {
        let newOffset = scrollView.contentView.bounds.origin.x
        if newOffset != headerView.xOffset {
            headerView.xOffset = newOffset
            headerView.needsDisplay = true
        }
        // Match spreadsheet behavior: scrolling commits any in-progress edit.
        bodyView.commitEditingIfNeeded()
    }

    /// Recompute content geometry after the data (or row count) changes.
    func reload() {
        let width = CGFloat(storage.columns.count) * Self.columnWidth
        let height = CGFloat(storage.rows.count) * Self.rowHeight
        bodyView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 1))
        bodyView.needsDisplay = true
        headerView.needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        headerView.frame = NSRect(x: 0, y: bounds.height - h, width: bounds.width, height: h)
        scrollView.frame = NSRect(x: 0, y: 0, width: bounds.width, height: bounds.height - h)
    }
}

// MARK: - Frozen column header

final class CSVHeaderView: NSView {
    weak var container: CSVTableContainerView?
    var xOffset: CGFloat = 0

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard let storage = container?.storage, !storage.columns.isEmpty else {
            NSColor.windowBackgroundColor.setFill()
            dirtyRect.fill()
            return
        }

        NSColor.windowBackgroundColor.setFill()
        bounds.fill()

        let colW = CSVTableContainerView.columnWidth
        let firstCol = max(0, Int(xOffset / colW))
        let lastCol = min(storage.columns.count - 1, Int((xOffset + bounds.width) / colW))
        guard lastCol >= firstCol else { return }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: para
        ]

        NSColor.gridColor.setStroke()
        let separators = NSBezierPath()
        for col in firstCol...lastCol {
            let x = CGFloat(col) * colW - xOffset
            let textRect = NSRect(x: x + 6, y: 5, width: colW - 12, height: 16)
            (storage.columns[col] as NSString).draw(in: textRect, withAttributes: attrs)
            separators.move(to: NSPoint(x: x + colW, y: 0))
            separators.line(to: NSPoint(x: x + colW, y: bounds.height))
        }
        // Bottom border under the header.
        separators.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        separators.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        separators.stroke()
    }
}

// MARK: - Scrollable, custom-drawn grid body

final class CSVGridBodyView: NSView, NSTextFieldDelegate {
    weak var container: CSVTableContainerView?

    private var editor: NSTextField?
    private var editingRow = -1
    private var editingCol = -1

    private var selectedRow = 0
    private var selectedCol = 0

    private var storage: CSVStorage { container?.storage ?? .empty }

    override var isFlipped: Bool { true }   // row 0 at the top
    override var isOpaque: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    private func cellRect(_ row: Int, _ col: Int) -> NSRect {
        NSRect(x: CGFloat(col) * CSVTableContainerView.columnWidth,
               y: CGFloat(row) * CSVTableContainerView.rowHeight,
               width: CSVTableContainerView.columnWidth,
               height: CSVTableContainerView.rowHeight)
    }

    /// Repaint a single cell (padded for the selection border).
    private func invalidateCell(_ row: Int, _ col: Int) {
        guard row >= 0, col >= 0 else { return }
        setNeedsDisplay(cellRect(row, col).insetBy(dx: -2, dy: -2))
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let rowH = CSVTableContainerView.rowHeight
        let colW = CSVTableContainerView.columnWidth

        // Opaque background for the whole exposed strip (incl. any blank area).
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()

        let storage = self.storage
        guard !storage.columns.isEmpty, !storage.rows.isEmpty else { return }

        let firstRow = max(0, Int(dirtyRect.minY / rowH))
        let lastRow = min(storage.rows.count - 1, Int(dirtyRect.maxY / rowH))
        let firstCol = max(0, Int(dirtyRect.minX / colW))
        let lastCol = min(storage.columns.count - 1, Int(dirtyRect.maxX / colW))
        guard lastRow >= firstRow, lastCol >= firstCol else { return }

        // Alternating row backgrounds.
        let altColors = NSColor.alternatingContentBackgroundColors
        for row in firstRow...lastRow where row % 2 == 1 {
            altColors[1 % altColors.count].setFill()
            NSRect(x: dirtyRect.minX, y: CGFloat(row) * rowH,
                   width: dirtyRect.width, height: rowH).fill()
        }

        // Grid lines (one coherent stroke — no per-cell view seams).
        NSColor.gridColor.setStroke()
        let grid = NSBezierPath()
        for col in firstCol...(lastCol + 1) {
            let x = CGFloat(col) * colW
            grid.move(to: NSPoint(x: x, y: dirtyRect.minY))
            grid.line(to: NSPoint(x: x, y: dirtyRect.maxY))
        }
        for row in firstRow...(lastRow + 1) {
            let y = CGFloat(row) * rowH
            grid.move(to: NSPoint(x: dirtyRect.minX, y: y))
            grid.line(to: NSPoint(x: dirtyRect.maxX, y: y))
        }
        grid.stroke()

        // Cell text — only the visible cells.
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.labelColor,
            .paragraphStyle: para
        ]

        for row in firstRow...lastRow {
            let rowData = storage.rows[row]
            for col in firstCol...lastCol where col < rowData.count {
                let value = rowData[col]
                if value.isEmpty { continue }
                let textRect = NSRect(x: CGFloat(col) * colW + 6,
                                      y: CGFloat(row) * rowH + (rowH - 16) / 2,
                                      width: colW - 12, height: 16)
                (value as NSString).draw(in: textRect, withAttributes: attrs)
            }
        }

        // Selection highlight (skipped while an editor covers the cell).
        if editor == nil,
           selectedRow >= firstRow, selectedRow <= lastRow,
           selectedCol >= firstCol, selectedCol <= lastCol {
            NSColor.controlAccentColor.setStroke()
            let outline = NSBezierPath(rect: cellRect(selectedRow, selectedCol).insetBy(dx: 1, dy: 1))
            outline.lineWidth = 2
            outline.stroke()
        }
    }

    // MARK: Editing (double-click a single cell)

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let col = Int(point.x / CSVTableContainerView.columnWidth)
        let row = Int(point.y / CSVTableContainerView.rowHeight)
        let storage = self.storage
        guard row >= 0, row < storage.rows.count,
              col >= 0, col < storage.columns.count else {
            super.mouseDown(with: event)
            return
        }

        if event.clickCount == 2 {
            beginEditing(row: row, col: col)
        } else {
            window?.makeFirstResponder(self)
            select(row: row, col: col)
        }
    }

    /// Move the selection to a specific cell.
    private func select(row: Int, col: Int) {
        let previousRow = selectedRow, previousCol = selectedCol
        selectedRow = row
        selectedCol = col
        invalidateCell(previousRow, previousCol)
        invalidateCell(row, col)
    }

    /// Move the selection by a delta, clamped to the grid, and scroll it into view.
    private func moveSelection(dRow: Int, dCol: Int) {
        let storage = self.storage
        guard !storage.rows.isEmpty, !storage.columns.isEmpty else { return }
        let row = min(max(0, selectedRow + dRow), storage.rows.count - 1)
        let col = min(max(0, selectedCol + dCol), storage.columns.count - 1)
        select(row: row, col: col)
        scrollToVisible(cellRect(row, col).insetBy(dx: -CSVTableContainerView.columnWidth, dy: 0))
    }

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 123: moveSelection(dRow: 0, dCol: -1)   // ←
        case 124: moveSelection(dRow: 0, dCol: 1)    // →
        case 125: moveSelection(dRow: 1, dCol: 0)    // ↓
        case 126: moveSelection(dRow: -1, dCol: 0)   // ↑
        case 36, 76:                                 // Return / Enter → edit
            beginEditing(row: selectedRow, col: selectedCol)
        default:
            // Type-to-edit: a printable key opens the cell and replaces its contents.
            if let chars = event.characters, let scalar = chars.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(scalar) {
                beginEditing(row: selectedRow, col: selectedCol)
                editor?.currentEditor()?.insertText(chars)
            } else {
                super.keyDown(with: event)
            }
        }
    }


    private func beginEditing(row: Int, col: Int) {
        let storage = self.storage
        guard row >= 0, row < storage.rows.count,
              col >= 0, col < storage.columns.count else { return }
        commitEditingIfNeeded()
        select(row: row, col: col)

        let colW = CSVTableContainerView.columnWidth
        let rowH = CSVTableContainerView.rowHeight
        let field = NSTextField(frame: NSRect(x: CGFloat(col) * colW,
                                              y: CGFloat(row) * rowH,
                                              width: colW, height: rowH))
        field.font = NSFont.systemFont(ofSize: 13)
        field.isBordered = true
        field.drawsBackground = true
        field.backgroundColor = .textBackgroundColor
        field.usesSingleLineMode = true
        field.delegate = self
        let rowData = storage.rows[row]
        field.stringValue = col < rowData.count ? rowData[col] : ""

        addSubview(field)
        editor = field
        editingRow = row
        editingCol = col
        window?.makeFirstResponder(field)
        field.selectText(nil)   // pre-select so typing replaces, spreadsheet-style
    }

    /// Commits the active edit (if any) back into storage and tears down the field.
    /// Reentrancy-safe: clears `editor` before removing the field, so the
    /// end-editing notification it triggers becomes a no-op.
    func commitEditingIfNeeded() {
        guard let field = editor else { return }
        editor = nil
        let row = editingRow, col = editingCol
        editingRow = -1
        editingCol = -1

        let storage = self.storage
        // Only a real change counts as an edit: opening a cell and closing it
        // untouched shouldn't mark the document dirty.
        var didChange = false
        if row >= 0, row < storage.rows.count, col >= 0 {
            while storage.rows[row].count <= col {
                storage.rows[row].append("")
            }
            didChange = storage.rows[row][col] != field.stringValue
            storage.rows[row][col] = field.stringValue
        }
        field.removeFromSuperview()
        if didChange {
            container?.onEdit?()
        }

        if row >= 0, col >= 0 {
            setNeedsDisplay(NSRect(x: CGFloat(col) * CSVTableContainerView.columnWidth,
                                   y: CGFloat(row) * CSVTableContainerView.rowHeight,
                                   width: CSVTableContainerView.columnWidth,
                                   height: CSVTableContainerView.rowHeight))
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        commitEditingIfNeeded()
    }

    /// Spreadsheet-style keyboard navigation while editing.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):       // Return → commit, move down
            commitAndMove(dRow: 1, dCol: 0)
            return true
        case #selector(NSResponder.insertTab(_:)):           // Tab → commit, move right
            commitAndMove(dRow: 0, dCol: 1)
            return true
        case #selector(NSResponder.insertBacktab(_:)):       // Shift-Tab → commit, move left
            commitAndMove(dRow: 0, dCol: -1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):     // Esc → discard edit
            cancelEditing()
            return true
        default:
            return false
        }
    }

    /// Commit the current edit and open the neighboring cell; at the grid edge,
    /// keep a clamped selection and return keyboard focus to the grid.
    private func commitAndMove(dRow: Int, dCol: Int) {
        let targetRow = editingRow + dRow
        let targetCol = editingCol + dCol
        commitEditingIfNeeded()
        beginEditing(row: targetRow, col: targetCol)
        if editor == nil {
            let storage = self.storage
            if !storage.rows.isEmpty, !storage.columns.isEmpty {
                select(row: min(max(0, targetRow), storage.rows.count - 1),
                       col: min(max(0, targetCol), storage.columns.count - 1))
            }
            window?.makeFirstResponder(self)
        }
    }

    /// Tears down the active edit WITHOUT writing back to storage.
    private func cancelEditing() {
        guard let field = editor else { return }
        editor = nil
        let row = editingRow, col = editingCol
        editingRow = -1
        editingCol = -1
        field.removeFromSuperview()
        window?.makeFirstResponder(self)   // resume keyboard navigation
        invalidateCell(row, col)
    }
}
