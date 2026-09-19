import AppKit
import SwiftUI

struct FileBrowserList: View {
    let entries: [WorkspaceFileEntry]
    let selection: URL?
    let isLocal: Bool
    let onSelect: (WorkspaceFileEntry) -> Void
    let onOpenInTerminal: (WorkspaceFileEntry) -> Void

    @State private var highlightedFile: URL?

    var body: some View {
        List(selection: $highlightedFile) {
            ForEach(entries) { entry in
                HStack(spacing: 8) {
                    Image(systemName: entry.icon)
                        .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                        .frame(width: 16)
                    Text(entry.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer()
                    if entry.isDirectory {
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .tag(entry.url)
                .onTapGesture(count: 1) {
                    highlightedFile = entry.url
                }
                .onTapGesture(count: 2) {
                    onSelect(entry)
                }
                .contextMenu {
                    if isLocal && !entry.isDirectory {
                        Button("Open in Default App", systemImage: "arrow.up.forward.app") {
                            NSWorkspace.shared.open(entry.url)
                        }
                    }
                    if entry.isDirectory {
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
        .onChange(of: selection, initial: true) { _, value in
            highlightedFile = value
        }
        .onChange(of: entries) { _, values in
            if let highlightedFile, !values.contains(where: { $0.url == highlightedFile }) {
                self.highlightedFile = nil
            }
        }
        .onKeyPress(.return) {
            guard let entry = entries.first(where: { $0.url == highlightedFile }) else {
                return .ignored
            }
            onSelect(entry)
            return .handled
        }
    }
}
