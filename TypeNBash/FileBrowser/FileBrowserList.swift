import AppKit
import SwiftUI

struct FileListRow<Tag: Hashable, LeadingItem: View, TrailingItem: View>: View {

    let filename: String
    let icon: FileTypeIcon
    let style: Color
    let tag: Tag
    let leadingItem: LeadingItem
    let trailingItem: TrailingItem

    init(
        filename: String,
        icon: FileTypeIcon,
        style: Color,
        tag: Tag,
        @ViewBuilder leadingItem: () -> LeadingItem = { EmptyView() },
        @ViewBuilder trailingItem: () -> TrailingItem
    ) {
        self.filename = filename
        self.icon = icon
        self.style = style
        self.tag = tag
        self.leadingItem = leadingItem()
        self.trailingItem = trailingItem()
    }

    var body: some View {
        HStack(spacing: 8) {
            leadingItem
            FileTypeIconView(icon: icon, symbolStyle: style)
            Text(filename)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer()
            trailingItem
        }
        .frame(height: 24)
        .contentShape(Rectangle())
        .tag(tag)
    }
}

/// The browser's rows, flat or as a tree. Every decision about what a click or
/// key does lives in `FileTreeModel`; this only draws rows and forwards input.
struct FileBrowserList: View {
    @Bindable var tree: FileTreeModel
    let isLocal: Bool
    let onOpen: (WorkspaceFileEntry) -> Void
    let onOpenInTerminal: (WorkspaceFileEntry) -> Void

    var body: some View {
        List(selection: $tree.selectedID) {
            ForEach(tree.rows) { row in
                let entry = row.entry
                FileListRow(
                    filename: entry.label,
                    icon: entry.icon,
                    style: entry.isDirectory ? Color.accentColor : Color.secondary,
                    tag: row.id,
                    leadingItem: {
                        if tree.layout == .tree { disclosure(for: row) }
                    },
                    trailingItem: { status(of: row) }
                )
                .padding(.leading, CGFloat(row.depth) * 14)
                .onTapGesture(count: 1) {
                    tree.selectedID = row.id
                }
                .onTapGesture(count: 2) {
                    onOpen(entry)
                }
                .contextMenu {
                    if isLocal && !entry.isDirectory {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(entry.url)
                        }
                    }
                    if entry.isDirectory {
                        if tree.layout == .tree {
                            Button("Open as Root", systemImage: "folder") {
                                tree.navigate(to: entry.url)
                            }
                        }
                        Button(entry.isDirectory ? "Open in Terminal" : "Open Folder in Terminal",
                               systemImage: "terminal") {
                            onOpenInTerminal(entry)
                        }
                    }
                    Divider()
                    Button("Copy Path", systemImage: "document.on.document") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(entry.url.path, forType: .string)
                    }
                    if isLocal {
                        Button("Reveal in Finder", systemImage: "folder") {
                            NSWorkspace.shared.activateFileViewerSelecting([entry.url])
                        }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        .onKeyPress(.return) {
            guard let entry = tree.selectedRow?.entry else { return .ignored }
            onOpen(entry)
            return .handled
        }
        .onKeyPress(.rightArrow) { tree.expandSelection() ? .handled : .ignored }
        .onKeyPress(.leftArrow) { tree.collapseSelection() ? .handled : .ignored }
    }

    /// Files get the same width empty, so names line up at every depth.
    private func disclosure(for row: FileTreeRow) -> some View {
        Button {
            tree.setExpanded(row.entry.url, !row.isExpanded)
        } label: {
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
                .frame(width: 12)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .opacity(row.entry.isDirectory ? 1 : 0)
        .disabled(!row.entry.isDirectory)
        .accessibilityLabel(row.isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder private func status(of row: FileTreeRow) -> some View {
        if row.isLoading {
            ProgressView().controlSize(.mini)
        } else if let failure = row.failure {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .help(failure)
        } else if tree.layout == .list && row.entry.isDirectory {
            Image(systemName: "chevron.right")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}
