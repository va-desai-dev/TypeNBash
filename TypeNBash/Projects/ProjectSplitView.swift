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
            splitView.dividerStyle = .thin
            let editorItem = NSSplitViewItem(viewController: self.editor)
            editorItem.minimumThickness = 480
            let consoleItem = NSSplitViewItem(viewController: self.console)
            consoleItem.minimumThickness = 0
            consoleItem.holdingPriority = .init(rawValue: 251)
            consoleItem.collapseBehavior = .useConstraints
            addSplitViewItem(editorItem)
            addSplitViewItem(consoleItem)
            footerSplit.onToggleConsole = { [weak self] in
                guard let self else { return }
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
            }
            footerSplit.updateConsoleButton(hidden: hidden)
        }

        override func splitView(_ splitView: NSSplitView, shouldHideDividerAt dividerIndex: Int) -> Bool {
            false
        }

        override func viewDidLayout() {
            super.viewDidLayout()
            guard !placedDivider, splitView.bounds.height > 200 else { return }
            placedDivider = true
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
