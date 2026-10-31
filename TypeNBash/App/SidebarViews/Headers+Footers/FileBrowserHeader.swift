//
//  FileBrowserNavigationControls.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import AppKit
import Defaults
import SwiftUI

/// Layout and sorting, hidden files, refresh, and creating folders and files.
struct FileBrowserActionControls: View {
    @Bindable var model: FileBrowserModel

    let action: () -> Void
    let showsSearch: Bool


    var body: some View {
        DynamicLiquidGlassStrip {
            FileBrowserViewOptionsMenu(tree: model.tree)
            Toggle(isOn: Bindable(model.tree).showsHiddenFiles) {
                if model.tree.showsHiddenFiles {
                    Label {
                        SwiftUI.Text("Showing Hidden Files")
                    } icon: {
                        Image(systemName: "eye.slash")
                    }
                } else {
                    Label {
                        SwiftUI.Text("Show Hidden Files")
                    } icon: {
                        Image(systemName: "eye")
                    }
                }
            }
            .toggleStyle(.button)
            .buttonStyle(.glassSegment)
            .help("Show hidden files")
            Button("Refresh", systemImage: "arrow.clockwise") {
                model.refresh()
            }
            .buttonStyle(.glassSegment)
        }
    }
}

/// List or tree, sort key and direction, and folders on top.
struct FileBrowserViewOptionsMenu: View {
    @Bindable var tree: FileTreeModel

    var body: some View {
        Menu {
            Picker("Layout", selection: $tree.layout) {
                ForEach(FileTreeLayout.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.inline)
            Picker("Sort By", selection: $tree.sortKey) {
                ForEach(FileTreeSortKey.allCases) { Text($0.title).tag($0) }
            }
            Picker("Order", selection: $tree.sortsAscending) {
                Text("Ascending").tag(true)
                Text("Descending").tag(false)
            }
            Toggle("Folders on Top", isOn: $tree.foldersFirst)
            if tree.layout == .tree {
                Divider()
                Button("Collapse All") { tree.collapseAll() }
            }
        } label: {
            Label("View Options", systemImage: tree.layout == .tree ? "list.bullet.indent" : "list.bullet")
        }
        .menuStyle(.button)
        .buttonStyle(.glassSegment)
        .menuIndicator(.hidden)
        .help("View Options")
    }
}
