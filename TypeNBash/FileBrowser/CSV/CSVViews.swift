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
    var session: EditorSession? = nil
    /// Called after a cell edit changes a value. The grid mutates `storage`
    /// directly, so this is the only signal SwiftUI gets that the data is dirty.
    var onEdit: (() -> Void)?

    func makeNSView(context: Context) -> CSVTableContainerView {
        let container = CSVTableContainerView()
        container.storage = storage
        container.onEdit = onEdit
        container.session = session
        container.setUp()
        return container
    }

    static func dismantleNSView(_ nsView: CSVTableContainerView, coordinator: ()) {
        nsView.endPreview()
    }

    func updateNSView(_ nsView: CSVTableContainerView, context: Context) {
        nsView.storage = storage
        nsView.onEdit = onEdit
        nsView.session = session
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
    let session: EditorSession

    @State private var storage: CSVStorage
    @State private var refreshTrigger = false

    init(table: CSVTable, session: EditorSession, onEdit: @escaping (CSVTable) -> Void) {
        self.session = session
        self.table = table
        self.onEdit = onEdit
        _storage = State(initialValue: CSVStorage(table))
    }

    var body: some View {
        FastCSVTableView(storage: storage, refreshTrigger: $refreshTrigger, session: session) {
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
    static let indexWidth: CGFloat = 30

    /// Gutter width that fits the widest row number, so a 100k-row file doesn't
    /// truncate its own index.
    static func indexWidth(for rowCount: Int) -> CGFloat {
        let digitCount = max(rowCount, 1).digits.count
        return max(indexWidth, CGFloat(digitCount) * 8 + 12)
    }

    var storage: CSVStorage = .empty
    var onEdit: (() -> Void)?

    /// Display order for the grid. Owned here because the header sets the rules
    /// and the body and gutter read them.
    let arrangement = CSVArrangement()

    weak var session: EditorSession?
    private var lastScrollOrigin = NSPoint.zero
    private var gutterWidth = CSVTableContainerView.indexWidth

    private let scrollView = NSScrollView()
    private let bodyView = CSVGridBodyView()
    private let headerView = CSVHeaderView()
    private let indexView = CSVIndexView()

    /// Fills the corner between the header and the index gutter; the subviews
    /// cover everything else.
    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.card).setFill()
        dirtyRect.fill()
    }

    func setUp() {
        headerView.container = self
        bodyView.container = self
        indexView.container = self
        // Keep the gutter background from painting over adjacent columns.
        indexView.clipsToBounds = true
        session?.csvGrid = bodyView

        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.backgroundColor = NSColor(Color.card)
        scrollView.documentView = bodyView

        // Treat Force Touch as an ordinary click so double-click-to-edit doesn't
        // fight the trackpad's deep-press (force-click) second stage.
        bodyView.pressureConfiguration = NSPressureConfiguration(pressureBehavior: .primaryClick)

        addSubview(scrollView)
        addSubview(headerView)
        addSubview(indexView)

        // Keep the frozen header and index gutter aligned with the body's scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(bodyDidScroll),
            name: NSView.boundsDidChangeNotification,
            object: scrollView.contentView
        )

        reload()
    }

    func endPreview() {
        bodyView.cancelEditing()
        if session?.csvGrid === bodyView {
            session?.csvGrid = nil
            session?.hasPendingCSVEdit = false
        }
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func bodyDidScroll() {
        let origin = scrollView.contentView.bounds.origin
        guard origin != lastScrollOrigin else { return }
        lastScrollOrigin = origin
        if origin.x != headerView.xOffset {
            headerView.xOffset = origin.x
            headerView.needsDisplay = true
        }
        if origin.y != indexView.yOffset {
            indexView.yOffset = origin.y
            indexView.needsDisplay = true
        }
        // Match spreadsheet behavior: scrolling commits any in-progress edit.
        bodyView.commitEditingIfNeeded()
        headerView.closePopover()
    }

    /// Recompute content geometry after the data (or row count) changes.
    func reload() {
        arrangement.rebuild(from: storage)
        let width = CGFloat(storage.columns.count) * Self.columnWidth
        let height = CGFloat(arrangement.rowCount) * Self.rowHeight
        bodyView.frame = NSRect(x: 0, y: 0, width: width, height: max(height, 1))
        bodyView.clampSelection()
        // Sized for the widest *file* row number, since the gutter shows those
        // rather than renumbering a filtered view.
        gutterWidth = Self.indexWidth(for: storage.rows.count)
        bodyView.needsDisplay = true
        headerView.needsDisplay = true
        indexView.needsDisplay = true
        needsLayout = true
    }

    /// Applies a column's popover rules. Sort is single-column, like clicking a
    /// header: setting one replaces any other. Filters accumulate across columns.
    func setRules(column: Int, direction: CSVArrangement.Direction?, filter: CSVArrangement.Filter) {
        bodyView.commitEditingIfNeeded()

        if let direction {
            arrangement.sortColumn = column
            arrangement.sortDirection = direction
        } else if arrangement.sortColumn == column {
            arrangement.sortColumn = nil
        }
        arrangement.filters[column] = filter.isActive ? filter : nil

        reload()
        // Rows have moved wholesale, so the old scroll position is meaningless.
        scrollView.contentView.scroll(to: NSPoint(x: scrollView.contentView.bounds.origin.x, y: 0))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Re-derives the display order after an edit to a sorted or filtered
    /// column, which may move the row or drop it out of the view.
    func rearrangeAfterEdit() {
        reload()
    }

    override func layout() {
        super.layout()
        let h = Self.headerHeight
        let g = gutterWidth
        headerView.frame = NSRect(x: g, y: bounds.height - h, width: bounds.width - g, height: h)
        scrollView.frame = NSRect(x: g, y: 0, width: bounds.width - g, height: bounds.height - h)
        indexView.frame = NSRect(x: 0, y: 0, width: g, height: bounds.height - h)
    }
}

// MARK: - Frozen row index gutter

/// The row-number gutter down the left edge — the header's mirror image: it
/// steps along `rowHeight` on the y axis and follows the body's *vertical*
/// scroll, and its own width is fixed by the container.
final class CSVIndexView: NSView {
    weak var container: CSVTableContainerView?
    var yOffset: CGFloat = 0

    override var isFlipped: Bool { true }   // row 0 at the top, matching the body
    override var isOpaque: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(Color.card).setFill()
        dirtyRect.fill()

        guard let container, !container.storage.rows.isEmpty else { return }
        let arrangement = container.arrangement

        let rowH = CSVTableContainerView.rowHeight
        let firstRow = max(0, Int((yOffset + dirtyRect.minY) / rowH))
        let lastRow = min(arrangement.rowCount - 1, Int((yOffset + dirtyRect.maxY) / rowH))
        guard lastRow >= firstRow else { return }

        let para = NSMutableParagraphStyle()
        para.alignment = .right
        let attrs: [NSAttributedString.Key: Any] = [
            // Monospaced digits so the numbers don't shimmer as they scroll.
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular),
            .foregroundColor: NSColor(Color.accentColor),
            .paragraphStyle: para
        ]

        let separators = NSBezierPath()
        for row in firstRow...lastRow {
            let y = CGFloat(row) * rowH - yOffset
            let textRect = NSRect(x: 0, y: y + (rowH - 14) / 2, width: bounds.width - 6, height: 14)
            // The number is the row's place in the *file*, not on screen: under a
            // filter it reads 1, 4, 17, which is what tells you which record
            // you're editing. Identical to sequential when nothing is arranged.
            let number = (arrangement.storageRow(row) ?? row) + 1
            (String(number) as NSString).draw(in: textRect, withAttributes: attrs)
            separators.move(to: NSPoint(x: 0, y: y + rowH))
            separators.line(to: NSPoint(x: bounds.width, y: y + rowH))
        }
        // Right border, separating the gutter from the grid.
        separators.move(to: NSPoint(x: bounds.width - 0.5, y: dirtyRect.minY))
        separators.line(to: NSPoint(x: bounds.width - 0.5, y: dirtyRect.maxY))
        // Text drawing can change the context color; set the line color last.
        NSColor(Color.accentColor.opacity(0.32)).setStroke()
        separators.stroke()
    }
}

// MARK: - Column sort/filter popover

/// The contents of a column header's arrangement popover.
///
/// Holds the rules as local state and pushes the whole pair back on every
/// change, so the grid reacts live as the user types a filter — matching
/// Numbers, where the table updates under the open popover.
struct CSVColumnArrangementMenu: View {
    let columnName: String
    private let onChange: (CSVArrangement.Direction?, CSVArrangement.Filter) -> Void

    @State private var direction: CSVArrangement.Direction?
    @State private var filter: CSVArrangement.Filter
    @State private var variableType: CSVArrangement.VariableFlag?
    private let onTypeChange: (CSVArrangement.VariableFlag?) -> Void

    init(columnName: String,
         direction: CSVArrangement.Direction?,
         filter: CSVArrangement.Filter,
         variableType: CSVArrangement.VariableFlag? = nil,
         onTypeChange: @escaping (CSVArrangement.VariableFlag?) -> Void = { _ in },
         onChange: @escaping (CSVArrangement.Direction?, CSVArrangement.Filter) -> Void) {
        self.columnName = columnName
        self.onChange = onChange
        _direction = State(initialValue: direction)
        _filter = State(initialValue: filter)
        _variableType = State(initialValue: variableType)
        self.onTypeChange = onTypeChange
    }

    private var hasRules: Bool { direction != nil || filter.isActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(columnName.isEmpty ? "Untitled Column" : columnName)
                .font(.headline)
                .foregroundStyle(Color.foreground)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            Picker("Variable type", selection: $variableType) {
                Text("Unspecified").tag(nil as CSVArrangement.VariableFlag?)
                ForEach(CSVArrangement.VariableFlag.allCases) { type in
                    Text(type.rawValue).tag(Optional(type))
                }
            }
            .help("Analysis hint for this open table; does not convert cells or change the CSV file")

            Text("Sort")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Sort", selection: $direction) {
                Text("None").tag(nil as CSVArrangement.Direction?)
                Text("A→Z").tag(CSVArrangement.Direction.ascending)
                Text("Z→A").tag(CSVArrangement.Direction.descending)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Divider()

            Text("Filter")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("Condition", selection: $filter.condition) {
                ForEach(CSVArrangement.Condition.allCases) { condition in
                    Text(condition.rawValue).tag(condition)
                }
            }
            .labelsHidden()

            if filter.condition.needsValue {
                TextField("Value", text: $filter.value)
                    .textFieldStyle(.roundedBorder)
            }

            Divider()

            Button("Clear Column Rules") {
                direction = nil
                filter = CSVArrangement.Filter()
            }
            .disabled(!hasRules)
        }
        .padding(12)
        .frame(width: 230)
        .tint(Color.accentColor)
        .onChange(of: variableType) { _, value in onTypeChange(value) }
        .onChange(of: direction) { _, newValue in onChange(newValue, filter) }
        .onChange(of: filter) { _, newValue in onChange(direction, newValue) }
    }
}

// MARK: - Frozen column header

final class CSVHeaderView: NSView {
    weak var container: CSVTableContainerView?
    var xOffset: CGFloat = 0

    /// Width reserved at the right of each header cell for the sort/filter glyph.
    private static let indicatorWidth: CGFloat = 16

    /// Held strongly so it survives until dismissed.
    private var popover: NSPopover?

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { true }

    // MARK: Popover

    /// A header click anywhere in the cell opens the popover — a bigger target
    /// than Numbers' chevron, which the glyph still advertises.
    override func mouseDown(with event: NSEvent) {
        guard let container, !container.storage.columns.isEmpty else {
            super.mouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let column = Int((point.x + xOffset) / CSVTableContainerView.columnWidth)
        guard column >= 0, column < container.storage.columns.count else {
            super.mouseDown(with: event)
            return
        }
        showPopover(for: column, in: container)
    }

    private func showPopover(for column: Int, in container: CSVTableContainerView) {
        closePopover()
        let arrangement = container.arrangement
        let menu = CSVColumnArrangementMenu(
            columnName: container.storage.columns[column],
            direction: arrangement.isSorted(column) ? arrangement.sortDirection : nil,
            filter: arrangement.filters[column] ?? CSVArrangement.Filter(),
            variableType: container.storage.columnTypes[column],
            onTypeChange: { [weak container] type in container?.storage.columnTypes[column] = type }
        ) { [weak container] direction, filter in
            container?.setRules(column: column, direction: direction, filter: filter)
        }

        let host = NSHostingController(rootView: menu)
        // Let SwiftUI's intrinsic size drive the popover; otherwise it opens at
        // a zero-ish content size and the rules are unreachable.
        host.sizingOptions = .preferredContentSize

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = host

        let colW = CSVTableContainerView.columnWidth
        let anchor = NSRect(x: CGFloat(column) * colW - xOffset, y: 0, width: colW, height: bounds.height)
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
    }

    /// Called when the grid scrolls: the popover is anchored to a rect that has
    /// moved, so leaving it open would point it at the wrong column.
    func closePopover() {
        popover?.close()
        popover = nil
    }

    // MARK: Indicator glyphs

    private static var symbolCache: [String: NSImage] = [:]

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        Self.symbolCache.removeAll()   // the cached images have a baked-in tint
        needsDisplay = true
    }

    private static func symbol(_ name: String, active: Bool) -> NSImage? {
        let key = "\(name)/\(active)"
        if let cached = symbolCache[key] { return cached }
        let color = active ? NSColor(Color.accentColor) : NSColor(Color.accentColor.opacity(0.45))
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
            .applying(NSImage.SymbolConfiguration(paletteColors: [color]))
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(config) else { return nil }
        symbolCache[key] = image
        return image
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let storage = container?.storage, !storage.columns.isEmpty else {
            NSColor(Color.card).setFill()
            dirtyRect.fill()
            return
        }

        NSColor(Color.card).setFill()
        bounds.fill()

        let colW = CSVTableContainerView.columnWidth
        let firstCol = max(0, Int(xOffset / colW))
        let lastCol = min(storage.columns.count - 1, Int((xOffset + bounds.width) / colW))
        guard lastCol >= firstCol else { return }

        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 12),
            .foregroundColor: NSColor(Color.accentColor),
            .paragraphStyle: para
        ]

        let arrangement = container?.arrangement ?? .identity
        let separators = NSBezierPath()
        for col in firstCol...lastCol {
            let x = CGFloat(col) * colW - xOffset
            let textRect = NSRect(x: x + 6, y: 5,
                                  width: colW - 12 - Self.indicatorWidth, height: 16)
            (storage.columns[col] as NSString).draw(in: textRect, withAttributes: attrs)

            // A chevron normally; the sort arrow or filter glyph when the column
            // carries a rule, so the arrangement is legible without clicking.
            // Sort wins the slot when a column has both.
            let sorted = arrangement.isSorted(col)
            let filtered = arrangement.isFiltered(col)
            let name = if sorted {
                arrangement.sortDirection == .ascending ? "arrow.up" : "arrow.down"
            } else if filtered {
                "line.3.horizontal.decrease"
            } else {
                "chevron.down"
            }
            if let glyph = Self.symbol(name, active: sorted || filtered) {
                let size = glyph.size
                let glyphRect = NSRect(x: x + colW - Self.indicatorWidth,
                                       y: (bounds.height - size.height) / 2,
                                       width: size.width, height: size.height)
                glyph.draw(in: glyphRect, from: .zero, operation: .sourceOver,
                           fraction: 1, respectFlipped: true, hints: nil)
            }

            separators.move(to: NSPoint(x: x + colW, y: 0))
            separators.line(to: NSPoint(x: x + colW, y: bounds.height))
        }
        // Bottom border under the header.
        separators.move(to: NSPoint(x: 0, y: bounds.height - 0.5))
        separators.line(to: NSPoint(x: bounds.width, y: bounds.height - 0.5))
        // Text drawing can change the context color; set the line color last.
        NSColor(Color.accentColor.opacity(0.32)).setStroke()
        separators.stroke()
    }
}

// MARK: - Scrollable, custom-drawn grid body

final class CSVGridBodyView: NSView, NSTextFieldDelegate {
    weak var container: CSVTableContainerView?

    private var isStartingEdit = false
    private var editor: NSTextField?
    private var editingRow = -1
    private var editingCol = -1

    private var selectedRow = 0
    private var selectedCol = 0

    func analysisSnapshot(scope: CSVAnalysisSnapshot.Scope) throws -> CSVAnalysisSnapshot {
        commitEditingIfNeeded()
        guard let container else { throw CSVAnalysisError.noTable }
        let storage = container.storage
        let rows = scope == .allRows ? Array(storage.rows.indices) : container.arrangement.visibleRows
        let table = scope == .allRows ? storage.table
            : CSVTable(columns: storage.columns, rows: rows.map { storage.rows[$0] })
        return CSVAnalysisSnapshot(table: table, sourceRows: rows, columnTypes: storage.columnTypes)
    }

    private var storage: CSVStorage { container?.storage ?? .empty }
    private var arrangement: CSVArrangement { container?.arrangement ?? .identity }

    /// `editingRow`, `selectedRow` and every row coming out of a mouse or key
    /// event are *display* rows. Anything that reads or writes cells has to
    /// resolve them through here first.
    private func storageRow(_ displayRow: Int) -> Int? {
        arrangement.storageRow(displayRow)
    }

    /// Rows currently on screen, which a filter can make far fewer than the file's.
    private var displayRowCount: Int { arrangement.rowCount }

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
        NSColor(Color.card).setFill()
        dirtyRect.fill()

        let storage = self.storage
        guard !storage.columns.isEmpty, !storage.rows.isEmpty else { return }

        let firstRow = max(0, Int(dirtyRect.minY / rowH))
        let lastRow = min(displayRowCount - 1, Int(dirtyRect.maxY / rowH))
        let firstCol = max(0, Int(dirtyRect.minX / colW))
        let lastCol = min(storage.columns.count - 1, Int(dirtyRect.maxX / colW))
        guard lastRow >= firstRow, lastCol >= firstCol else { return }


        // Grid lines (one coherent stroke — no per-cell view seams).
        NSColor(Color.accentColor.opacity(0.2)).setStroke()
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
            guard let rowData = storageRow(row).map({ storage.rows[$0] }) else { continue }
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
            NSColor(Color.accentColor).setStroke()
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
        guard row >= 0, row < displayRowCount,
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

    /// Pull the selection back inside the grid after a filter shrinks it, so the
    /// highlight doesn't sit below the last visible row.
    func clampSelection() {
        guard displayRowCount > 0, !storage.columns.isEmpty else {
            selectedRow = 0
            selectedCol = 0
            return
        }
        selectedRow = min(selectedRow, displayRowCount - 1)
        selectedCol = min(selectedCol, storage.columns.count - 1)
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
        guard displayRowCount > 0, !storage.columns.isEmpty else { return }
        let row = min(max(0, selectedRow + dRow), displayRowCount - 1)
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
            guard event.modifierFlags.intersection([.command, .control]).isEmpty else {
                super.keyDown(with: event)
                return
            }
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
        guard row >= 0, row < displayRowCount,
              col >= 0, col < storage.columns.count else { return }
        commitEditingIfNeeded()
        select(row: row, col: col)
        isStartingEdit = true
        defer { isStartingEdit = false }
        scrollToVisible(cellRect(row, col))

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
        let rowData = storageRow(row).map { storage.rows[$0] } ?? []
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
        guard !isStartingEdit, let field = editor else { return }
        let value = field.currentEditor()?.string ?? field.stringValue
        editor = nil
        container?.session?.hasPendingCSVEdit = false
        let row = editingRow, col = editingCol
        editingRow = -1
        editingCol = -1

        let storage = self.storage
        // Only a real change counts as an edit: opening a cell and closing it
        // untouched shouldn't mark the document dirty.
        var didChange = false
        if let target = storageRow(row), col >= 0 {
            while storage.rows[target].count <= col {
                storage.rows[target].append("")
            }
            didChange = storage.rows[target][col] != value
            storage.rows[target][col] = value
        }
        if field.currentEditor() != nil { window?.makeFirstResponder(self) }
        field.removeFromSuperview()
        if didChange {
            container?.onEdit?()
            // The new value may re-sort this row or push it out of a filter, so
            // the display order has to be re-derived before the next repaint.
            if arrangement.affectsArrangement(column: col) {
                container?.rearrangeAfterEdit()
                return
            }
        }

        if row >= 0, col >= 0 {
            setNeedsDisplay(NSRect(x: CGFloat(col) * CSVTableContainerView.columnWidth,
                                   y: CGFloat(row) * CSVTableContainerView.rowHeight,
                                   width: CSVTableContainerView.columnWidth,
                                   height: CSVTableContainerView.rowHeight))
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        guard let field = editor, let target = storageRow(editingRow) else { return }
        let value = field.currentEditor()?.string ?? field.stringValue
        let row = storage.rows[target]
        container?.session?.hasPendingCSVEdit = value != (editingCol < row.count ? row[editingCol] : "")
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
            if displayRowCount > 0, !storage.columns.isEmpty {
                select(row: min(max(0, targetRow), displayRowCount - 1),
                       col: min(max(0, targetCol), storage.columns.count - 1))
            }
            window?.makeFirstResponder(self)
        }
    }

    /// Tears down the active edit WITHOUT writing back to storage.
    func cancelEditing() {
        guard let field = editor else { return }
        editor = nil
        container?.session?.hasPendingCSVEdit = false
        let row = editingRow, col = editingCol
        editingRow = -1
        editingCol = -1
        field.removeFromSuperview()
        window?.makeFirstResponder(self)   // resume keyboard navigation
        invalidateCell(row, col)
    }
}
