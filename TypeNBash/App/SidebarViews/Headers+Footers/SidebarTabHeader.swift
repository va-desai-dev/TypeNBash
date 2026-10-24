//
//  SidebarTabs.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//
import SwiftUI
import AppKit

enum SidebarTabs: String, CaseIterable, Hashable, Sendable, Identifiable {
    case files = "Project"
    case git = "Source Control"
    case search = "Find"
    case notebook = "Analysis Notebook"

    var id: String { rawValue }

    var menuLabel: String {
        switch self {
            case .files, .notebook: "Add New"
            case .git: "Options"
            case .search: "Review Replace"
        }
    }
    var menuHelp: String {
        switch self {
            case .files, .notebook: "Add new files & folders"
            case .git: "Source control commands"
            case .search: "Review and replace matches"
        }
    }
    /// The footer filter field's prompt, naming what it narrows.
    var filterPlaceholder: String {
        switch self {
            case .files, .notebook: "Find Files"
            case .git: "Filter Changes"
            case .search: "Filter Results by Path"
        }
    }
    var menuIcon: String {
        switch self {
            case .files, .notebook: "plus"
            case .git: "ellipsis"
            case .search: "checkmark"
        }
    }
    
    var icon: Image {
        switch self {
            case .files: Image(systemName: "folder")
            case .git: Image("vault.symbols.2")
            case .search: Image(systemName: "magnifyingglass")
            case .notebook: Image(systemName: "function")
        }
    }
    var nsImage: NSImage? {
        switch self {
            case .files: NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            case .git: NSImage(symbolName: "vault.symbols.2", bundle: .main, variableValue: 1)
            case .search: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
            case .notebook: NSImage(systemSymbolName: "function", accessibilityDescription: nil)
        }
    }
}

struct SidebarTabPicker: View {
    @Binding var selection: SidebarTabs

    var body: some View {
        FillingTabStrip(accessibilityLabel: "Sidebar Tabs", tabs: SidebarTabs.allCases,
                        selection: $selection, title: \.rawValue) { .image($0.nsImage) }
    }
}
/// Back, enclosing folder, and forward through the browsed directories.
struct FileBrowserNavigationControls: View {
    let tree: FileTreeModel

    var body: some View {
        ControlGroup {
            Button { tree.goBack() } label: {
                Image(systemName: "chevron.left")
            }
            .disabled(!tree.canGoBack)
            .help("Back")
            Button { tree.goUp() } label: {
                Image(systemName: "smallcircle.filled.circle")
            }
            .disabled(!tree.canGoUp)
            .help("Enclosing folder")
            Button { tree.goForward() } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(!tree.canGoForward)
            .help("Forward")
        }
        .controlSize(.regular)
    }
}
