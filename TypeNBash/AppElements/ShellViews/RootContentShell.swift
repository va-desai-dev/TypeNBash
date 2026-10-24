//
//  CanvasView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI

/// Shared window chrome. Feature state belongs to the selected workspace view.
struct CanvasView<Content: View, Sidebar: View, Inspector: View>: View {
    let windowSession: WindowSession
    let terminalController: TerminalController
    let onOpenInTerminal: () -> Void
    var sidebarRevealRequest = 0
    @ViewBuilder let content: Content
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let inspector: Inspector
    @State private var showsSidebar = true
    @State private var showsInspector = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        CanvasSplitView(showsSidebar: $showsSidebar, showsInspector: $showsInspector) {
            sidebar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.card)
        } content: {
            content
                .background(Color.card)
        } inspector: {
            inspector
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.card)
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    showsSidebar.toggle()
                } label: {
                    Image(systemName: "sidebar.leading")
                }
                .help(showsSidebar ? "Hide sidebar" : "Show sidebar")
            }
            ToolbarSpacer()
                .sharedBackgroundVisibility(.hidden)
            ToolbarItem {
                Button {
                        showsInspector.toggle()
                } label: {
                    Image(systemName: "sidebar.trailing")
                }
                .help(showsInspector ? "Hide inspector" : "Show inspector")
            }
        }
        .toolbar(removing: .title)
        .onChange(of: sidebarRevealRequest) { showsSidebar = true }
        .containerBackground(Color.card, for: .window)
        .toolbarBackground(Color.card, for: .windowToolbar)
    }

    private func openInTerminal(_ entry: WorkspaceFileEntry) {
        let directory = entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
        terminalController.changeDirectory(to: directory.path)
        onOpenInTerminal()
    }
}
