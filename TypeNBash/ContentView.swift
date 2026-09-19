//
//  ContentView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

import SwiftUI

struct ContentView: View {
    // Passed straight through to `TelemetryInspector`; not observed here so a
    // telemetry tick doesn't re-run this body (and the sidebar/file table with it).
    @State private var monitor = SystemMonitor()
    @State private var selectedView = ViewMode.terminal
    var body: some View {
        CanvasView(monitor: monitor, selectedViewMode: $selectedView)
            .frame(minWidth: 860, minHeight: 560)
    }
}

enum ViewMode: CaseIterable, Identifiable, Hashable, Sendable {
    var id: Self { self }
    case terminal
    case previewMode
}

struct CanvasView: View {
    @State private var projectStore = ProjectStore()
    @State private var windowSession = WindowSession()
    @State private var terminalController = TerminalController()
    @State private var profileStore = SSHProfileStore()
    @State private var showsInspector = false
    @State private var presentedSheet: CanvasSheet?
    // Forwarded to `TelemetryInspector`; deliberately not observed here so telemetry
    // updates (1 Hz CPU/GPU timers) don't invalidate the sidebar and file table,
    // which was causing the scroll jank.
    let monitor: SystemMonitor
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?
    @State private var showsSidebar = true
    // One session per window, owned here because it is the nearest common
    // ancestor of the three views that share it: the header issues editor
    // actions through it, `FileViewer` hands it to the text view, and the
    // footer reads the cursor position back out. Each view minting its own
    // left the header's commands and the footer's readout wired to nothing.
    @State private var editorSession = EditorSession()

    @Binding var selectedViewMode: ViewMode
    @State private var project = Project.self
    // The comparison session, owned here for the same reason as `editorSession`:
    // `GitDiffFileList` in the sidebar and `GitDiffView` in the canvas are
    // siblings, and selecting a row in one has to reload the other. Non-nil is
    // also what "the comparison is open" means, so there is no separate flag to
    // fall out of step with it.
    @State private var diffModel: GitDiffModel?

    var body: some View {
        Group {
            if let diffModel {
                GitDiffView(model: diffModel)
            } else {
                mainCanvas
            }
        }
        .toolbar {
            appToolbar()
        }
        .toolbar(removing: .title)
        .containerBackground(Color.card, for: .window)
        .toolbarBackground(Color.card, for: .windowToolbar)
        .sheet(item: $presentedSheet) { destination in
            switch destination {
                case .sshConnection:
                    SSHConnectionSheet(windowSession: windowSession, profileStore: profileStore)
                case .projectCreator:
                    ProjectCreationSheet(windowSession: windowSession, profileStore: profileStore)
                case .sourceControl:
                    SourceControlView(directory: windowSession.activeProject?.localDirectoryURL
                                      ?? windowSession.fileBrowser.directory)
            }
        }
        .task(id: telemetryTaskID) {
            await windowSession.streamTelemetry(to: monitor)
        }
        // The first load is driven here, not inside `GitDiffView`, so the
        // sidebar list still fills when a comparison is opened while the
        // terminal is the front pane. Later reloads come from the model itself.
        .task(id: diffModel.map { ObjectIdentifier($0) }) {
            await diffModel?.refresh()
        }
        .onDisappear { windowSession.close() }
    }

    private var mainCanvas: some View {
        HSplitView {
            if showsSidebar {
                sidebar
                    .frame(minWidth: 250, maxWidth: 300)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .backgroundStyle(Color.card)
            }
            ZStack {
                TerminalHostView(
                    configuration: windowSession.terminalConfiguration,
                    controller: terminalController,
                    onDirectoryChange: { [generation = windowSession.terminalGeneration] host, directory in
                        windowSession.terminalReported(host: host, directory: directory, generation: generation)
                    },
                    onExit: { [generation = windowSession.terminalGeneration] _ in
                        windowSession.handleTerminalExit(generation: generation)
                    }
                )
                .id(windowSession.terminalGeneration)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .allowsHitTesting(selectedViewMode == .terminal)

                if selectedViewMode != .terminal {
                    FileViewer(model: windowSession.fileBrowser, session: editorSession)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .id(ObjectIdentifier(windowSession.fileBrowser))
                        .safeAreaBar(edge: .top) {
                            FileBrowserPaneHeader(model: windowSession.fileBrowser, session: editorSession)
                        }
                        .safeAreaBar(edge: .bottom) {
                            FileViewerFooter(session: editorSession)
                                .background(Color.card)
                        }
                }
            }
            .backgroundStyle(Color.card)
            if showsInspector {
                inspector
                    .frame(minWidth: 220, idealWidth: 240, maxWidth: 300)
            }
        }
    }

    private var telemetryTaskID: String {
        String(windowSession.terminalGeneration)
    }


    // Split across three builders because `ToolbarContentBuilder` only composes
    // ten children per block, and the toolbar has grown past that.
    @ToolbarContentBuilder private func appToolbar() -> some ToolbarContent {
        navigationToolbarContent
        workspaceToolbarContent
        inspectorToolbarContent
    }


    @ToolbarContentBuilder private var navigationToolbarContent: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                showsSidebar.toggle()
            } label: {
                Image(systemName: "sidebar.leading")
            }
            .help(showsInspector ? "Hide sidebar" : "Show sidebar")
        }
        ToolbarSpacer(.fixed, placement: .navigation)
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem {
            Button {
                presentedSheet = .sshConnection
            } label: {
                Label("SSH", systemImage: "network")
                    .foregroundStyle(windowSession.location != .local ? .green : .primary)
            }
            .symbolEffect(.pulse, options: .repeat(.max), value: windowSession.location != .local)
            .help("Connect this window over SSH")
        }
        ToolbarItem {
            Button {
                presentedSheet = .projectCreator
            } label: {
                Label("Project", systemImage: "folder")
            }
            .help("Open a project workspace")
        }
    }


    @ToolbarContentBuilder private var workspaceToolbarContent: some ToolbarContent {
        ToolbarSpacer()
        if #available(macOS 27, *) {
            ToolbarItem() {
                Picker("Workspace mode", selection: $selectedViewMode) {
                    Label("Terminal", systemImage: "terminal")
                        .tag(ViewMode.terminal)
                    Label("Editor", systemImage: "square.and.pencil")
                        .tag(ViewMode.previewMode)
                }
                .pickerStyle(.tabs)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
                .fixedSize()
                .help("Switch between the terminal and file editor")
            }
        } else {
            ToolbarItem() {
                Picker("Workspace mode", selection: $selectedViewMode) {
                    Label("Terminal", systemImage: "terminal")
                        .tag(ViewMode.terminal)
                    Label("Editor", systemImage: "square.and.pencil")
                        .tag(ViewMode.previewMode)
                }
                .pickerStyle(.segmented)
                .labelStyle(.titleAndIcon)
                .labelsHidden()
                .fixedSize()
                .help("Switch between the terminal and file editor")
            }
        }
        ToolbarSpacer()
        ToolbarItem {
            Button {
                presentedSheet = .sourceControl
            } label: {
                Label("Source Control", image: "vault.symbols.2")
            }
            .disabled(windowSession.location != .local)
            .help("Source control for the local workspace")
        }
        ToolbarItem {
            Button(action: toggleDiffs) {
                Label("Changes", systemImage: "arrow.left.arrow.right").font(.system(size: 12))
            }
            .disabled(windowSession.location != .local)
            .help("Compare saved Git changes")
        }
    }


    @ToolbarContentBuilder private var inspectorToolbarContent: some ToolbarContent {
        ToolbarSpacer(.fixed)
        ToolbarItem {
            Button {
                showsInspector.toggle()
            } label: {
                Image(systemName: "sidebar.trailing")
            }
            .help(showsInspector ? "Hide inspector" : "Show inspector")
        }
    }


    /// The sidebar becomes the changed-file list while a comparison is open.
    /// Both panes read the one session, so clicking a row here is the same
    /// `select(_:)` that reloads the diff on the right.
    @ViewBuilder private var leadingPane: some View {
        if let diffModel {
            GitDiffFileList(model: diffModel)
        } else {

        }
    }

    /// Opening mints the session; closing drops it, so the next open picks up
    /// whatever project and file are current instead of the pair that happened
    /// to be selected the first time.
    private func toggleDiffs() {
        guard diffModel == nil else {
            diffModel = nil
            return
        }
        diffModel = GitDiffModel(
            directory: windowSession.activeProject?.localDirectoryURL
            ?? windowSession.fileBrowser.directory,
            selectedFile: windowSession.fileBrowser.selectedFile
        )
        selectedViewMode = .previewMode
    }

    private var sidebar: some View {
        FileBrowserView(
            model: windowSession.fileBrowser,
            isLocal: windowSession.location == .local,
            onOpenInTerminal: openInTerminal
        )
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                FileBrowserToolbar(
                    model: windowSession.fileBrowser,
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
                    Text(windowSession.fileBrowser.directory.path(percentEncoded: false))
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
            Text("Create a folder in “\(windowSession.fileBrowser.directory.lastPathComponent)”.")
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
            if let error = await windowSession.fileBrowser.newFolder(named: name) {
                newFolderError = error
            }
        }
    }

    private func openInTerminal(_ entry: WorkspaceFileEntry) {
        let directory = entry.isDirectory
        ? entry.url.path
        : entry.url.deletingLastPathComponent().path
        terminalController.changeDirectory(to: directory)
        selectedViewMode = .terminal
    }

    private var inspector: some View {
        ScrollView {
            TelemetryInspector(monitor: monitor)
        }
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .padding(16)
        .background(Color.card)
    }
}

private enum EditorPanels: String, Identifiable {
    case editor
    case diff

    var id: Self { self }
}

private enum CanvasSheet: String, Identifiable {
    case sshConnection
    case projectCreator
    case sourceControl

    var id: Self { self }
}
