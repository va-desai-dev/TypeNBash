import SwiftUI

enum ViewMode: CaseIterable, Identifiable, Hashable, Sendable {
    var id: Self { self }
    case terminal
    case previewMode
}

struct ContentView: View {
    let router: AppRouter

    var body: some View {
        Group {
            if let project = router.session.activeProject {
                ProjectWorkspaceView(session: router.session)
                    .id(project.id)
            } else {
                FreeWorkspaceView(session: router.session)
            }
        }
    }
}

//MARK: FREEMODE CANVAS
private struct FreeWorkspaceView: View {
    let session: WindowSession
    @State private var terminalController = TerminalController()
    @State private var selectedViewMode = ViewMode.terminal
    @State private var inspectorSelection: InspectorTabs = .telemtry
    @State private var writingSubselection: WritingInspectorSubtabs = .stats

    var body: some View {
        CanvasView(windowSession: session, terminalController: terminalController,
                   onOpenInTerminal: { selectedViewMode = .terminal }) {
            ZStack {
                TerminalPane(session: session, controller: terminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(selectedViewMode == .terminal ? 1 : 0)
                    .allowsHitTesting(selectedViewMode == .terminal)
                    .accessibilityHidden(selectedViewMode != .terminal)

                if selectedViewMode != .terminal {
                    WorkspacePane(model: session.fileBrowser)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
        } sidebar: {
            WorkspaceSidebar(
                model: session.fileBrowser,
                isLocal: session.location == .local,
                onOpenInTerminal: { _ in selectedViewMode = .terminal },
                showsSearch: false,
                action: {}
            )
        } inspector: { WorkspaceInspector(
            session: session,
            selection: $inspectorSelection,
            subselection: $writingSubselection
        )
        }
        .toolbar {
            ToolbarItem {
                Group {
                    if #available(macOS 27, *) {
                        modePicker.pickerStyle(.tabs)
                    } else {
                        modePicker.pickerStyle(.segmented)
                    }
                }
                .labelStyle(.titleAndIcon)
                .labelsHidden()
                .fixedSize()
                .help("Switch between the terminal and file editor")
            }
        }
    }

    private var modePicker: some View {
        Picker("Workspace mode", selection: $selectedViewMode) {
            Label("Terminal", systemImage: "terminal").tag(ViewMode.terminal)
            Label("Editor", systemImage: "square.and.pencil").tag(ViewMode.previewMode)
        }
    }
}

//MARK: WORKSPACECANVAS
/// Lives for one project. Editor, comparison and console state end with it.
struct ProjectWorkspaceView: View {
    let session: WindowSession
    @State private var editorSession: EditorSession
    @State private var terminalController = TerminalController()
    @State private var diffModel: GitDiffModel?
    @State private var isFiltering = false
    @State private var isNamingFolder = false
    @State private var newFolderName = ""
    @State private var newFolderError: String?
    /// Retained across toggles so results survive a trip back to the editor;
    /// each reopen recaptures the table.
    @State private var notebook: NotebookModel?
    @State private var showsNotebook = false
    @State private var showsSourceControl = false
    @State private var hideConsole = true
    @State private var inspectorSelection: InspectorTabs = .agents
    @State private var writingSubselection: WritingInspectorSubtabs = .citations
    @State private var search: ProjectSearchModel
    @State private var gitModel: SourceControlModel
    @State private var isCommitting = false
    @State private var gitNotice: GitNotice?

    @State private var selectedTab: SidebarTabs = .files

    init(session: WindowSession) {
        self.session = session
        let editor = EditorSession()
        _editorSession = State(initialValue: editor)
        _search = State(initialValue: ProjectSearchModel(session: session, editor: editor))
        _gitModel = State(
            initialValue: SourceControlModel(
                directory: session.rootDirectory,
                remote: session.remoteGit,
                identitySettings: .shared
            )
        )
    }

    var body: some View {
        CanvasView(windowSession: session, terminalController: terminalController, onOpenInTerminal: { hideConsole = false },
                   sidebarRevealRequest: search.focusRequest) {
            ProjectSplitView(hideConsole: $hideConsole) {
                Group {
                    if showsNotebook, let notebook {
                        NotebookView(model: notebook, showsFooter: false, onOpenScript: openScript)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let diffModel {
                        GitDiffView(model: diffModel, showsFooter: false)
                    } else {
                        WorkspacePane(model: session.fileBrowser, bibliography: session.bibliography, session: editorSession,
                                      showsFooter: false, onRunInConsole: runInConsole)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            } footer: {
                // The split view draws the divider above this slot.
                PaneBar(edge: .bottom, showsDivider: false) {
                    if showsNotebook, let notebook {
                        NotebookMissingCodesField(model: notebook)
                        NotebookStaleCaptureWarning(model: notebook)
                        Spacer()
                    } else if let diffModel {
                        GitDiffStatusLabel(model: diffModel)
                        Spacer()
                        Text("Read-only · − Removed / + Added")
                    } else {
                        Text(editorSession.position)
                        Spacer()
                        EditorIndentationLabel()
                    }
                }
            } console: {
                TerminalPane(session: session, controller: terminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } sidebar: {
            Sidebar(
                session: session,
                diffModel: diffModel,
                selectedTab: $selectedTab,
                showsNotebook: $showsNotebook,
                hideConsole: $hideConsole,
                search: search,
                content: {
                    searchfooterMenuItems(tab: selectedTab)
                },
                isFiltering: $isFiltering,
                treeModel: session.fileBrowser.tree,
                openSearchResult: openSearchResult
            )
        } inspector: { WorkspaceInspector(
            session: session,
            selection: $inspectorSelection,
            subselection: $writingSubselection
        )
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showsSourceControl = true
                } label: {
                    Label("Source Control", image: "vault.symbols.2")
                }
                .help("Source control for this project")
            }
        }
        .sheet(isPresented: $showsSourceControl) {
            SourceControlView(directory: session.rootDirectory, remote: session.remoteGit)
        }
        // The footer's model only refreshes while its tab is showing; opening
        // the tab refreshes it too. Its own posts already left it current.
        .onReceive(NotificationCenter.default.publisher(for: .gitRepositoryDidChange)) { note in
            guard selectedTab == .git, note.object as AnyObject? !== gitModel else { return }
            Task { await gitModel.run(.refresh) }
        }
        .alert("Commit Staged Changes", isPresented: $isCommitting) {
            TextField("Commit message", text: $gitModel.commitMessage)
            Button("Commit") { runGit { await gitModel.run(.commit(gitModel.commitMessage)) } }
                .disabled(!gitModel.canCommit)
            Button("Cancel", role: .cancel) { }
        } message: {
            let staged = gitModel.snapshot?.changes.filter(\.staged).count ?? 0
            Text("\(staged) staged \(staged == 1 ? "file" : "files") on “\(gitModel.snapshot?.branch ?? "")”. The commit is saved locally until you push.")
        }
        .alert(gitNotice?.title ?? "", isPresented: Binding(
            get: { gitNotice != nil }, set: { if !$0 { gitNotice = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(gitNotice?.message ?? "")
        }
        .task(id: diffModel.map { ObjectIdentifier($0) }) {
            await diffModel?.refresh()
        }
        // The sidebar tab is the single source of truth for what the canvas
        // shows; toolbar buttons and navigation only ever change the tab.
        .onChange(of: selectedTab) { _, tab in showCanvas(for: tab) }
        // ⇧⌘F and the file browser's Find button land on the Find tab.
        .onChange(of: search.focusRequest) { selectedTab = .search }
        .onChange(of: session.terminalGeneration) {
            search.reset()
            selectedTab = .files
            diffModel = nil
            showsNotebook = false
            notebook = nil
            showsSourceControl = false
        }
        .onChange(of: session.fileBrowser.searchText) { search.bufferDidChange() }
        .focusedSceneValue(\.projectSearch, search)
        .onDisappear { search.cancel() }
        .onChange(of: isFiltering) { _, isShown in
            if !isShown { session.fileBrowser.tree.filter = "" }
        }
        .alert("New Folder", isPresented: $isNamingFolder) {
            TextField("Folder name", text: $newFolderName)
            Button("Create", action: createFolder)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Create a folder in “\(session.fileBrowser.tree.targetDirectory.lastPathComponent)”.")
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

    @ViewBuilder private func searchfooterMenuItems(tab: SidebarTabs) -> some View {
        switch tab  {
            case .files, .notebook:
                Button("New File") {
                    session.fileBrowser.newFile()
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help("New File")
                Button("New Folder") {
                    newFolderName = "untitled folder"
                    isNamingFolder = true
                }
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .help("New Folder")
            case .search:
                Button("Replace…") { search.previewReplacement() }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity)
                    .help("Preview Replace All…")
                    .disabled(!search.canReplace)
            case .git:
                gitFooterMenuItems
        }
    }

    /// The active session's repository commands. Results and failures come
    /// back as an alert, since nothing else in the sidebar shows them.
    @ViewBuilder private var gitFooterMenuItems: some View {
        let snapshot = gitModel.snapshot
        let remotes = snapshot?.remotes ?? []
        Button("Refresh", systemImage: "arrow.clockwise") { runGit { await gitModel.run(.refresh) } }
            .disabled(gitModel.isBusy)
        Divider()
        Button("Stage All") { runGit { await gitModel.stageAll() } }
            .disabled(gitModel.isBusy || gitModel.stageablePaths.isEmpty)
        Button("Restore All") { runGit { await gitModel.unstageAll() } }
            .disabled(gitModel.isBusy || gitModel.unstagablePaths.isEmpty)
        // A missing identity is set in the sheet, which already has that form.
        Button(gitModel.needsIdentity ? "Set Commit Identity…" : "Commit…") {
            if gitModel.needsIdentity { showsSourceControl = true } else { isCommitting = true }
        }
        .disabled(gitModel.isBusy || snapshot?.changes.contains(where: \.staged) != true
                  || snapshot?.changes.contains(where: \.conflicted) == true)
        Divider()
        remoteCommand("Fetch", systemImage: "arrow.down", remotes: remotes) { remote in
            runGit { await gitModel.run(.fetch(remote)) }
        }
        .disabled(gitModel.isBusy || remotes.isEmpty)
        remoteCommand("Push \(snapshot?.branch ?? "Branch")", systemImage: "arrow.up", remotes: remotes) { remote in
            runGit { await gitModel.run(.push(remote)) }
        }
        .disabled(gitModel.isBusy || remotes.isEmpty || snapshot?.unborn != false || snapshot?.detached != false)
        Divider()
        Button("Open Source Control…") { showsSourceControl = true }
    }

    /// One remote acts directly; several become a submenu, with the
    /// remote the sheet last chose first.
    @ViewBuilder private func remoteCommand(_ title: String, systemImage: String, remotes: [String],
                                            action: @escaping (String) -> Void) -> some View {
        if remotes.count > 1 {
            Menu(title, systemImage: systemImage) {
                let preferred = remotes.filter { $0 == gitModel.selectedRemote }
                ForEach(preferred + remotes.filter { $0 != gitModel.selectedRemote }, id: \.self) { remote in
                    Button(remote) { action(remote) }
                }
            }
        } else {
            Button(remotes.first.map { "\(title) · \($0)" } ?? title, systemImage: systemImage) {
                remotes.first.map(action)
            }
        }
    }

    private func runGit(_ operation: @escaping () async -> Void) {
        Task {
            await operation()
            if let error = gitModel.errorMessage {
                gitNotice = GitNotice(title: "Source Control Failed", message: error)
            } else if let result = gitModel.resultMessage {
                gitNotice = GitNotice(title: "Source Control", message: result)
            }
        }
    }


    /// Leaves the notebook for the editor, on the script it just wrote.
    ///
    /// The script reads its data by project-relative path, so the console has to
    /// be at the project root for those reads to resolve. It usually already is,
    /// and moving it anyway would paste a `cd` into whatever has the foreground
    /// — an R session would just report a syntax error — so this only sends one
    /// when the last report says it is somewhere else.
    private func openScript(_ url: URL) {
        session.fileBrowser.select(WorkspaceFileEntry(url: url, isDirectory: false, byteCount: nil))
        selectedTab = .files
        let root = session.rootDirectory.standardizedFileURL
        if session.consoleDirectory?.standardizedFileURL != root {
            hideConsole = false
            terminalController.changeDirectory(to: root.path)
        }
    }

    /// Sends a snippet to this project's console, revealing it if it was hidden.
    /// Output lands there and stays there — nothing reads it back.
    private func runInConsole(_ snippet: String) {
        hideConsole = false
        terminalController.send(snippet)
    }

    private func toggleNotebook() {
        selectedTab = selectedTab == .notebook ? .files : .notebook
    }

    private func toggleDiffs() {
        selectedTab = selectedTab == .git ? .files : .git
    }

    /// Puts the canvas in step with the sidebar tab. Source Control and the
    /// notebook own the canvas; Project and Find show the editor.
    ///
    /// The notebook captures the editor's table *before* swapping the pane
    /// out, because showing the notebook unmounts the grid the capture reads
    /// from. `showsNotebook` is still false while this runs, so the grid is
    /// still mounted.
    private func showCanvas(for tab: SidebarTabs) {
        switch tab {
            case .git:
                showsNotebook = false
                // Nothing else loads the footer's model, whose snapshot its
                // menu commands are enabled from.
                Task { await gitModel.run(.refresh) }
                if diffModel == nil {
                    diffModel = GitDiffModel(directory: session.rootDirectory, selectedFile: session.fileBrowser.selectedFile,
                                             remote: session.remoteGit)
                }
            case .notebook:
                diffModel = nil
                let model = notebook ?? NotebookModel(session: session, editor: editorSession)
                model.captureOpenTable()
                notebook = model
                showsNotebook = true
            case .files, .search:
                showsNotebook = false
                diffModel = nil
        }
    }

    private func openSearchResult(_ file: ProjectSearchResult, _ match: ProjectSearchMatch) {
        Task { _ = await search.open(file, match: match) }
    }
    private func createFolder() {
        let name = newFolderName
        Task {
            if let error = await
                session.fileBrowser.newFolder(named: name) {
                newFolderError = error
            }
        }
    }
}


/// The outcome of a sidebar footer Git command.
struct GitNotice {
    let title: String
    let message: String
}

struct Sidebar<Content: View>: View {
    let session: WindowSession
    let diffModel: GitDiffModel?
    @Binding var selectedTab: SidebarTabs
    @Binding var showsNotebook: Bool
    @Binding var hideConsole: Bool
    let search: ProjectSearchModel
    @ViewBuilder var content: Content
    @Binding var isFiltering: Bool
    let treeModel: FileTreeModel

    
    let openSearchResult: (ProjectSearchResult, ProjectSearchMatch) -> Void

    /// The footer field filters whichever list the tab shows, and each tab
    /// keeps its own text, so switching tabs never carries a filter across.
    private var filter: Binding<String> {
        switch selectedTab {
            case .files, .notebook:
                Binding(get: { treeModel.filter }, set: { treeModel.filter = $0 })
            case .search:
                Binding(get: { search.pathFilter }, set: { search.pathFilter = $0 })
            case .git:
                diffModel.map { model in Binding(get: { model.fileFilter }, set: { model.fileFilter = $0 }) }
                    ?? .constant("")
        }
    }

    var body: some View {
        ZStack {
            if selectedTab == .search {
                ProjectSearchView(
                    model: search,
                    onOpen: openSearchResult,
                    files: session.fileBrowser
                )
            } else if let diffModel, selectedTab == .git {
                GitDiffFileList(model: diffModel, files: session.fileBrowser)
            } else {
                WorkspaceSidebar(
                    model: session.fileBrowser,
                    isLocal: session.location == .local,
                    onOpenInTerminal: { _ in hideConsole = false },
                    showsSearch: true,
                    action: search.reveal
                )
            }
        }
        .safeAreaInset(edge: .top, alignment: .center) {
            PaneBar {
                SidebarTabPicker(selection: $selectedTab)
            }
        }
        .safeAreaInset(edge: .bottom, alignment: .center) {
            SidebarFooterSearch(
                menuLabel: selectedTab.menuLabel,
                menuIcon: selectedTab.menuIcon,
                menuHelp: selectedTab.menuHelp,
                filter: filter,
                filterPlaceholder: selectedTab.filterPlaceholder,
                isFiltering: $isFiltering,
                menuItems: {
                    content
                }
            )
        }
    }
}
