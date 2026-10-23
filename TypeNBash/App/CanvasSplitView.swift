import SwiftUI

/// Sidebar · content · inspector columns. AppKit owns the column widths.
///
/// `HSplitView` re-applied each pane's ideal width whenever its content
/// changed, so opening a file in the editor snapped a dragged sidebar back to
/// its default. Same fix as `ProjectSplitView`: panes never propose a size.
struct CanvasSplitView<Sidebar: View, Content: View, Inspector: View>: NSViewControllerRepresentable {
    var showsSidebar: Bool
    var showsInspector: Bool
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
        controller.setCollapsed(!showsSidebar, at: 0)
        controller.setCollapsed(!showsInspector, at: 2)
    }

    final class Controller: NSSplitViewController {
        let sidebar: NSHostingController<Sidebar>
        let content: NSHostingController<Content>
        let inspector: NSHostingController<Inspector>

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
            sidebarItem.minimumThickness = 250
            sidebarItem.maximumThickness = 300
            sidebarItem.canCollapse = true
            // Window resizes go to the content column, not the side columns.
            sidebarItem.holdingPriority = .init(rawValue: 260)
            let contentItem = NSSplitViewItem(viewController: self.content)
            contentItem.minimumThickness = 262
            let inspectorItem = NSSplitViewItem(viewController: self.inspector)
            inspectorItem.minimumThickness = 260
            inspectorItem.maximumThickness = 300
            inspectorItem.canCollapse = true
            inspectorItem.holdingPriority = .init(rawValue: 260)
            addSplitViewItem(sidebarItem)
            addSplitViewItem(contentItem)
            addSplitViewItem(inspectorItem)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

        func setCollapsed(_ collapsed: Bool, at index: Int) {
            let item = splitViewItems[index]
            if item.isCollapsed != collapsed { item.isCollapsed = collapsed }
        }
    }
}
