import SwiftUI

/// AppKit owns divider geometry; SwiftUI only supplies each pane's content.
struct ProjectSplitView<Editor: View, Footer: View, Console: View>: NSViewControllerRepresentable {
    @Binding var hideConsole: Bool
    @ViewBuilder let editor: Editor
    @ViewBuilder let footer: Footer
    @ViewBuilder let console: Console

    func makeNSViewController(context: Context) -> Controller {
        Controller(editor: editor, footer: footer, console: console)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.editor.rootView = editor
        controller.console.rootView = console
        controller.footerSplit.updateFooter(footer)
        controller.onConsoleHiddenChange = { hideConsole = $0 }
        controller.setConsoleHidden(hideConsole)
    }

    /// Always take the space SwiftUI offers. Left to the default, SwiftUI sizes
    /// this view from the split's Auto Layout fitting size, and a divider drag
    /// with the console collapsed shrinks that to editor + divider — so the
    /// whole split squeezed toward the centre of its column mid-drag.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        proposal.replacingUnspecifiedDimensions()
    }


    final class Controller: NSSplitViewController {
        let editor: NSHostingController<Editor>
        let console: NSHostingController<Console>
        let footerSplit: FooterSplitView<Footer>
        private var placedDivider = false
        var onConsoleHiddenChange: ((Bool) -> Void)?

        init(editor: Editor, footer: Footer, console: Console) {
            footerSplit = FooterSplitView(footer: footer)
            self.editor = NSHostingController(rootView: editor)
            self.console = NSHostingController(rootView: console)
            super.init(nibName: nil, bundle: nil)
            // Pane contents must not propose a new split size when a file changes.
            self.editor.sizingOptions = []
            self.console.sizingOptions = []
            splitView = footerSplit
            splitView.isVertical = false
            splitView.dividerStyle = .paneSplitter
            let editorItem = NSSplitViewItem(viewController: self.editor)
            editorItem.minimumThickness = 0
            let consoleItem = NSSplitViewItem(viewController: self.console)
            consoleItem.minimumThickness = 0
            consoleItem.holdingPriority = .init(rawValue: 250)
            addSplitViewItem(editorItem)
            addSplitViewItem(consoleItem)
            footerSplit.onToggleConsole = { [weak self] in
                guard let self else { return }
                // A console dragged down to nothing is still expanded, so collapsing
                // it would change nothing on screen. Bring it back up instead.
                if !self.splitViewItems[1].isCollapsed, self.console.view.frame.height < 1 {
                    self.placeDivider()
                    self.footerSplit.updateConsoleButton(hidden: false)
                    return
                }
                let hidden = !self.splitViewItems[1].isCollapsed
                self.setConsoleHidden(hidden)
                self.onConsoleHiddenChange?(hidden)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        override func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect,
                                forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            NSRect(x: drawnRect.minX, y: drawnRect.minY,
                   width: max(0, drawnRect.width - FooterSplitView<Footer>.controlsWidth),
                   height: drawnRect.height)
        }

        func setConsoleHidden(_ hidden: Bool) {
            if splitViewItems[1].isCollapsed != hidden {
                splitViewItems[1].isCollapsed = hidden
                // Settle the panes now; otherwise the revealed console keeps its old
                // frame over the editor for a frame before the split re-divides.
                splitView.layoutSubtreeIfNeeded()
            }
            footerSplit.updateConsoleButton(hidden: hidden)
        }

        override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            false
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !placedDivider, splitView.bounds.height > 200 else { return }
            // The first pass sizes the split view before its panes, and a position
            // set against zero-height panes is not kept: the console would remember
            // the whole height and flash over the editor on its next reveal.
            guard splitView.arrangedSubviews.contains(where: { $0.frame.height > 0 }) else {
                DispatchQueue.main.async { [weak self] in self?.view.needsLayout = true }
                return
            }
            placedDivider = true
            // Placing the divider un-collapses the console, so size it expanded and
            // then put back whatever the binding asked for.
            let consoleItem = splitViewItems[1]
            let hidden = consoleItem.isCollapsed
            consoleItem.isCollapsed = false
            placeDivider()
            consoleItem.isCollapsed = hidden
        }

        /// Gives the console its default height above the bottom edge.
        private func placeDivider() {
            splitView.setPosition(max(120, splitView.bounds.height - 260 - splitView.dividerThickness),
                                  ofDividerAt: 0)
        }
    }
}

/// Status content lives inside the divider gap, never as a third split pane.
final class FooterSplitView<Footer: View>: NSSplitView {
    private let footer: DividerContentView<Footer>
    private var footerHeight: CGFloat = 0
    static var controlsWidth: CGFloat { 36 }
    private let consoleButton = NSButton()
    var onToggleConsole: (() -> Void)?

    init(footer: Footer) {
        self.footer = DividerContentView(rootView: footer)
        super.init(frame: .zero)
        arrangesAllSubviews = false
        addSubview(self.footer)
        consoleButton.setButtonType(.pushOnPushOff)
        consoleButton.isBordered = false
        consoleButton.image = NSImage(systemSymbolName: "inset.filled.bottomthird.square", accessibilityDescription: nil)
        consoleButton.imagePosition = .imageOnly
        consoleButton.target = self
        consoleButton.action = #selector(toggleConsole)
        consoleButton.identifier = NSUserInterfaceItemIdentifier("project.console.toggle")
        addSubview(consoleButton)
        updateConsoleButton(hidden: false)
        updateFooter(footer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var dividerThickness: CGFloat { footerHeight + 2 }

    func updateFooter(_ content: Footer) {
        footer.rootView = content
        let height = ceil(footer.fittingSize.height)
        if footerHeight != height {
            footerHeight = height
            needsLayout = true
        }
    }

    override func layout() {
        super.layout()
        guard let upper = arrangedSubviews.first, arrangedSubviews.count == 2 else { return }
        footer.frame = NSRect(x: bounds.minX, y: upper.frame.maxY + 1,
                              width: max(0, bounds.width - Self.controlsWidth), height: footerHeight)
        consoleButton.frame = NSRect(x: bounds.maxX - Self.controlsWidth + 4,
                                     y: upper.frame.maxY + 1, width: Self.controlsWidth - 8,
                                     height: footerHeight)
    }

    func updateConsoleButton(hidden: Bool) {
        consoleButton.state = hidden ? .off : .on
        consoleButton.toolTip = hidden ? "Show Console" : "Hide Console"
        consoleButton.setAccessibilityLabel(consoleButton.toolTip)
    }

    @objc private func toggleConsole() {
        onToggleConsole?()
    }

    /// The footer and the button sit in the divider gap as non-arranged subviews,
    /// and `NSSplitView` hit-tests only its arranged panes — a point in the gap
    /// is the divider as far as it is concerned. So both are offered the point
    /// first; the footer declines anything that is not one of its own controls.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        if consoleButton.frame.contains(localPoint) { return consoleButton }
        if footer.frame.contains(localPoint), let control = footer.hitTest(localPoint) { return control }
        return super.hitTest(point)
    }

    override func drawDivider(in rect: NSRect) {
        NSColor(Color.card).setFill()
        rect.fill()
        NSColor.separatorColor.setFill()
        NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1).fill()
        NSRect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1).fill()
    }
}

/// Footer status labels remain accessible, while pointer events reach the native divider.
///
/// Passive content is why: SwiftUI draws a label without any AppKit view of its
/// own, so a hit that lands on this hosting view *is* the footer's background
/// and belongs to the divider. A control is the other case — a text field or a
/// stepper backs onto a real view in this subtree — and handing that hit to the
/// divider is what made the control unclickable. So the pass-through is now
/// "nothing of mine was hit" rather than "never".
private final class DividerContentView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let target = super.hitTest(point)
        return target === self ? nil : target
    }
}

/// Column floors, shared by the split items and the window's minimum size.
private enum CanvasColumns {
    static let sidebarMinimum: CGFloat = 250
    static let contentMinimum: CGFloat = 400
    static let inspectorMinimum: CGFloat = 260
    static let minimumHeight: CGFloat = 560
}

/// Sidebar · content · inspector columns. AppKit owns the column widths.
///
/// `HSplitView` re-applied each pane's ideal width whenever its content
/// changed, so opening a file in the editor snapped a dragged sidebar back to
/// its default. Same fix as `ProjectSplitView`: panes never propose a size.
struct CanvasSplitView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    @Binding var showsSidebar: Bool
    @Binding var showsInspector: Bool
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let content: Content
    @ViewBuilder let inspector: Inspector


    func makeNSViewController(context: Context) -> Controller {
        Controller(sidebar: sidebar, content: content, inspector: inspector)
    }

    func updateNSViewController(_ controller: Controller, context: Context) {
        controller.sidebar.rootView = sidebar
        controller.content.rootView = content
        controller.inspector.rootView = inspector
        controller.onCollapseChange = { index, collapsed in
            if index == 0 { showsSidebar = !collapsed } else { showsInspector = !collapsed }
        }
        controller.setCollapsed(!showsSidebar, at: 0)
        controller.setCollapsed(!showsInspector, at: 2)
    }

    /// Same reason as `ProjectSplitView`: a column drag must never feed the
    /// split's fitting size back into SwiftUI's layout of the window. The one
    /// exception is the floor: the open columns' minimums, which the window
    /// (`.windowResizability(.contentSize)`) takes as its minimum size.
    func sizeThatFits(_ proposal: ProposedViewSize, nsViewController: Controller, context: Context) -> CGSize? {
        let size = proposal.replacingUnspecifiedDimensions()
        var minimumWidth = CanvasColumns.contentMinimum
        if showsSidebar { minimumWidth += CanvasColumns.sidebarMinimum + 1 }
        if showsInspector { minimumWidth += CanvasColumns.inspectorMinimum + 1 }
        return CGSize(width: max(size.width, minimumWidth), height: max(size.height, CanvasColumns.minimumHeight))
    }

    final class Controller: NSSplitViewController {
        let sidebar: NSHostingController<Sidebar>
        let content: NSHostingController<Content>
        let inspector: NSHostingController<Inspector>
        /// Collapse state per column as SwiftUI last set or was last told it.
        private var collapsed: [Int: Bool] = [:]
        private var collapseObservations: [NSKeyValueObservation] = []
        var onCollapseChange: ((Int, Bool) -> Void)?

        init(sidebar: Sidebar, content: Content, inspector: Inspector) {
            self.sidebar = NSHostingController(rootView: sidebar)
            self.content = NSHostingController(rootView: content)
            self.inspector = NSHostingController(rootView: inspector)
            super.init(nibName: nil, bundle: nil)
            self.sidebar.sizingOptions = []
            self.content.sizingOptions = []
            self.inspector.sizingOptions = []
            splitView.isVertical = true
            splitView.dividerStyle = .thin

            let sidebarItem = NSSplitViewItem(viewController: self.sidebar)
            sidebarItem.minimumThickness = CanvasColumns.sidebarMinimum
            sidebarItem.maximumThickness = 300
            sidebarItem.canCollapse = true
            // Window resizes go to the content column, not the side columns.
            sidebarItem.holdingPriority = .init(rawValue: 260)
            let contentItem = NSSplitViewItem(viewController: self.content)
            contentItem.minimumThickness = CanvasColumns.contentMinimum
            let inspectorItem = NSSplitViewItem(viewController: self.inspector)
            inspectorItem.minimumThickness = CanvasColumns.inspectorMinimum
            inspectorItem.maximumThickness = 300
            inspectorItem.canCollapse = true
            inspectorItem.holdingPriority = .init(rawValue: 260)
            addSplitViewItem(sidebarItem)
            addSplitViewItem(contentItem)
            addSplitViewItem(inspectorItem)
            // A divider drag or window resize collapses a column inside AppKit.
            // Report it, or the next SwiftUI update re-opens the column and the
            // toolbar button's first click only catches its state back up.
            for (index, item) in [(0, sidebarItem), (2, inspectorItem)] {
                collapseObservations.append(item.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
                    MainActor.assumeIsolated {
                        guard let self, self.collapsed[index] != item.isCollapsed else { return }
                        self.collapsed[index] = item.isCollapsed
                        self.onCollapseChange?(index, item.isCollapsed)
                    }
                })
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setCollapsed(_ collapsed: Bool, at index: Int) {
            // Recorded first so the collapse observer sees no change to report.
            self.collapsed[index] = collapsed
            let item = splitViewItems[index]
            if item.isCollapsed != collapsed {
                item.isCollapsed = collapsed
                splitView.layoutSubtreeIfNeeded()
            }
        }
    }
}
