import SwiftUI

/// Shared window chrome. Feature state belongs to the selected workspace view.
struct CanvasView<Content: View, Sidebar: View, Inspector: View>: View {
    let windowSession: WindowSession
    let terminalController: TerminalController
    let onOpenInTerminal: () -> Void
    @ViewBuilder let content: Content
    @ViewBuilder let sidebar: Sidebar
    @ViewBuilder let inspector: Inspector
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
                inspector
                    .frame(minWidth: 260, maxWidth: 300, maxHeight: .infinity, alignment: .topLeading)
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
    /// Lives here because both the header (which toggles it) and the viewer
    /// (which renders it) hang off this pane.
    @State private var mdViewSelection: MDViewStyle = .fancy

    var body: some View {
        FileViewer(model: model, session: session, mdViewSelection: mdViewSelection)
            .safeAreaBar(edge: .top) {
                FileBrowserPaneHeader(
                    model: model,
                    session: session,
                    mdViewSelection: $mdViewSelection,
                    onRunInConsole: onRunInConsole
                )
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
struct WorkspaceInspector: View {
    let session: WindowSession
    @State private var monitor: SystemMonitor?
    @Binding var selection: InspectorTabs

    var body: some View {
        // A real container, not a Group: Group forwards its modifiers to its
        // children, so while `monitor` is still nil the telemetry/process cases
        // have no children, nothing mounts, and the `.task` that creates the
        // monitor never runs.
        ZStack {
            switch selection {
                case .telemtry:
                    if let monitor {
                        ScrollView {
                            VStack {
                                TelemetryInspector(monitor: monitor)
                            }
                        }
                    }
                case .process:
                    if let monitor {
                        ScrollView {
                            VStack {
                                TopProcessesView(monitor: monitor)
                            }
                        }
                    }
                case .agents:
                    if let agent = session.agent {
                        AgenticChatView(session: agent)
                            .id(ObjectIdentifier(agent))
                    } else {
                        ContentUnavailableView(
                            "No Project Open",
                            systemImage: "folder",
                            description: Text("Agents work inside a project's folder.")
                        )
                    }
                case .writing:
                    WritingInspector(model: session.fileBrowser)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: session.terminalGeneration) {
            let monitor = monitor ?? SystemMonitor()
            self.monitor = monitor
            await session.streamTelemetry(to: monitor)
        }
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                header
                Divider()
            }
            .background(Color.card)
        }
    }
    private var header: some View {
            // On macOS a menu Picker is an NSPopUpButton: each row is flattened to an
            // NSMenuItem (one image + one title), so Spacers/HStacks inside rows are
            // ignored, and the button hugs its widest item unless told to be flexible.
            Picker("Inspector", selection: $selection) {
                ForEach(InspectorTabs.allCases) { tab in
                    Label(tab.rawValue.capitalized, systemImage: tab.icon)
                        .tag(tab)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .buttonSizing(.flexible)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
    }
}

enum InspectorTabs: String, CaseIterable, Identifiable {
    case telemtry, process, agents, writing
    var id: String { rawValue }
    var icon: String {
        switch self {
            case .telemtry: return "gauge.with.dots.needle.33percent"
            case .process: return "list.bullet.circle"
            case .agents: return "bubble.circle"
            case .writing: return "pencil.line"
        }
    }
}

import SwiftUI

struct GridPicker<Value: Hashable, Content: View>: View {
    let selection: Binding<Value>
    let items: [Value]
    let columns: [GridItem]
    let content: (Value) -> Content

    init(
        selection: Binding<Value>,
        items: [Value],
        columns: [GridItem] = [GridItem(.adaptive(minimum: 80, maximum: 120))],
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.selection = selection
        self.items = items
        self.columns = columns
        self.content = content
    }

    var body: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(items, id: \.self) { item in
                Button(action: { selection.wrappedValue = item }) {
                    content(item)
                }
                .buttonStyle(.accessoryBar)
            }
        }
    }
}


