//
//  WorkspaceSidebar.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//
import SwiftUI


struct WorkspaceSidebar: View {
    let model: FileBrowserModel
    let isLocal: Bool
    let onOpenInTerminal: (WorkspaceFileEntry) -> Void
    let showsSearch: Bool
    let action: () -> Void

    /// Whether the footer shows the filter field instead of the folder path.

    @State private var isFiltering = false
    var body: some View {
        FileBrowserView(
            model: model,
            isLocal: isLocal,
            onOpenInTerminal: onOpenInTerminal
        )
        .paneBar(.top) {
            PaneBar {
                FileBrowserNavigationControls(tree: model.tree)
                Spacer()
                FileBrowserActionControls(
                    model: model,
                    action: action,
                    showsSearch: showsSearch
                )
            }
        }
    }
}

struct SidebarFooterSearch<Content: View>: View {
    let menuLabel: String
    let menuIcon: String
    let menuHelp: String
    /// The current tab's filter text; see `SidebarTabs.filterPlaceholder`.
    @Binding var filter: String
    let filterPlaceholder: String
    @Binding var isFiltering: Bool
    @ViewBuilder let menuItems: Content


    var body: some View {
        HStack(alignment: .center) {
            Menu {
                menuItems
            } label: {
                Label(menuLabel, systemImage: menuIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .frame(width: 28, height: 28)
                    .glassEffect(.regular, in: .circle)
            }
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .help(menuHelp)
            BrowserSearchInput(
                text: $filter,
                placeholder: filterPlaceholder,
                onDismiss: { isFiltering = true
                })
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
