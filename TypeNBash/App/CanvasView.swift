import SwiftUI

/// Shared window chrome. Feature state belongs to the selected workspace view.
struct CanvasView<Content: View, Sidebar: View>: View {
    let windowSession: WindowSession
    let terminalController: TerminalController
    let onOpenInTerminal: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let sidebar: Sidebar
    @State private var showsSidebar = true
    @State private var showsInspector = false


    var body: some View {
        HSplitView {
            if showsSidebar {
                sidebar
                    .frame(minWidth: 250, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                    .background(Color.card)
            }
            content
                .background(Color.card)
            if showsInspector {
                WorkspaceInspector(session: windowSession)
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
                    .padding(16)
                    .background(Color.card)
            }
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
        .containerBackground(Color.card, for: .window)
        .toolbarBackground(Color.card, for: .windowToolbar)
    }

    private func openInTerminal(_ entry: WorkspaceFileEntry) {
        let directory = entry.isDirectory ? entry.url : entry.url.deletingLastPathComponent()
        terminalController.changeDirectory(to: directory.path)
        onOpenInTerminal()
    }
}

struct WorkspaceEditorPane: View {
    let model: FileBrowserModel
    @State var session = EditorSession()
    var showsFooter = true
    /// Present only where a console is mounted, which is project mode.
    var onRunInConsole: ((String) -> Void)?

    var body: some View {
        FileViewer(model: model, session: session)
            .safeAreaBar(edge: .top) {
                FileBrowserPaneHeader(model: model, session: session, onRunInConsole: onRunInConsole)
            }
            .safeAreaBar(edge: .bottom) {
                if showsFooter {
                    FileViewerFooter(session: session)
                        .background(Color.card)
                }
            }
    }
}

struct WorkspaceTerminalPane: View {
    let session: WindowSession
    let controller: TerminalController

    var body: some View {
        TerminalHostView(
            configuration: session.terminalConfiguration,
            controller: controller,
            onDirectoryChange: { [generation = session.terminalGeneration] host, directory in
                session.terminalReported(host: host, directory: directory, generation: generation)
            },
            onExit: { [generation = session.terminalGeneration] _ in
                session.handleTerminalExit(generation: generation)
            }
        )
        .id(session.terminalGeneration)
    }
}


struct WorkspaceSidebar: View {
    let model: FileBrowserModel
    let isLocal: Bool
    let onOpenInTerminal: (WorkspaceFileEntry) -> Void
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?

    var body: some View {
        FileBrowserView(
            model: model,
            isLocal: isLocal,
            onOpenInTerminal: onOpenInTerminal
        )
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                FileBrowserToolbar(
                    model: model,
                    isNamingFolder: $isNamingFolder,
                    newFolderName: $newFolderName
                )
                Divider()
            }
            .background(Color.card)
        }
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                Divider()
                HStack(alignment: .center) {
                    Image(systemName: "folder.fill")
                        .foregroundStyle(Color(NSColor.controlAccentColor))
                    Text(model.directory.path(percentEncoded: false))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
            }
            .background(Color.card)
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create", action: createFolder)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Create a folder in “\(model.directory.lastPathComponent)”.")
        }
        .alert(
            "Couldn’t Create Folder",
            isPresented: Binding(
                get: { newFolderError != nil },
                set: { if !$0 { newFolderError = nil } }
            )
        ) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(newFolderError ?? "")
        }
    }
    private func createFolder() {
        let name = newFolderName
        Task {
            if let error = await model.newFolder(named: name) {
                newFolderError = error
            }
        }
    }
}

/// Sampling is active only while the inspector is mounted.
private struct WorkspaceInspector: View {
    let session: WindowSession
    @State private var monitor: SystemMonitor?

    var body: some View {
        ScrollView {
            if let monitor {
                TelemetryInspector(monitor: monitor)
            }
        }
        .task(id: session.terminalGeneration) {
            let monitor = monitor ?? SystemMonitor()
            self.monitor = monitor
            await session.streamTelemetry(to: monitor)
        }
    }
}
