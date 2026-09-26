import SwiftUI

/// Lives for one project. Editor, comparison and console state end with it.
struct ProjectWorkspaceView: View {
    let session: WindowSession
    @State private var editorSession = EditorSession()
    @State private var terminalController = TerminalController()
    @State private var diffModel: GitDiffModel?
    /// Retained across toggles so results survive a trip back to the editor;
    /// each reopen recaptures the table.
    @State private var notebook: NotebookModel?
    @State private var showsNotebook = false
    @State private var showsSourceControl = false
    @State private var hideConsole = true

    var body: some View {
        CanvasView(windowSession: session, terminalController: terminalController, onOpenInTerminal: { hideConsole = false }) {
            ProjectSplitView(hideConsole: $hideConsole) {
                Group {
                    if showsNotebook, let notebook {
                        NotebookView(model: notebook, showsFooter: false, onOpenScript: openScript)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let diffModel {
                        GitDiffView(model: diffModel, showsFooter: false)
                    } else {
                        WorkspaceEditorPane(model: session.fileBrowser, session: editorSession,
                                            showsFooter: false, onRunInConsole: runInConsole)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            } footer: {
                Group {
                    if showsNotebook, let notebook {
                        NoteBookFooter(
                            model: notebook,
                            showsSeparator: false)
                    } else if let diffModel {
                        GitDiffFooter(model: diffModel, showsSeparator: false)
                    } else {
                        FileViewerFooter(
                            showsSeparator: false,
                            session: editorSession
                        )
                    }
                }
                .background(Color.card)
            } console: {
                WorkspaceTerminalPane(session: session, controller: terminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        } sidebar: {
            if let diffModel {
                GitDiffFileList(model: diffModel)
            } else {
            WorkspaceSidebar(
                model: session.fileBrowser,
                isLocal: session.location == .local,
                onOpenInTerminal: { _ in hideConsole = false }
            )
            }
        }
        .toolbar {
            ToolbarItem {
                Button(action: toggleNotebook) {
                    Label("Notebook", systemImage: "function")
                }
                .help(showsNotebook ? "Return to the editor" : "Analyze the open table")
            }
            ToolbarItem {
                Button {
                    showsSourceControl = true
                } label: {
                    Label("Source Control", image: "vault.symbols.2")
                }
                .help("Source control for this project")
            }
            ToolbarItem {
                Button(action: toggleDiffs) {
                    Label("Changes", systemImage: "arrow.left.arrow.right")
                }
                .help(diffModel == nil ? "Compare saved Git changes" : "Return to the editor")
            }
        }
        .sheet(isPresented: $showsSourceControl) {
            SourceControlView(directory: session.rootDirectory, remote: session.remoteGit)
        }
        .task(id: diffModel.map { ObjectIdentifier($0) }) {
            await diffModel?.refresh()
        }
        .onChange(of: session.terminalGeneration) {
            diffModel = nil
            showsNotebook = false
            notebook = nil
            showsSourceControl = false
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
        showsNotebook = false
        diffModel = nil
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

    /// Captures the editor's table *before* swapping the pane out, because
    /// showing the notebook unmounts the grid the capture reads from.
    private func toggleNotebook() {
        if showsNotebook { showsNotebook = false; return }
        let model = notebook ?? NotebookModel(session: session, editor: editorSession)
        model.captureOpenTable()
        notebook = model
        diffModel = nil
        showsNotebook = true
    }

    private func toggleDiffs() {
        if diffModel != nil {
            diffModel = nil
        } else {
            diffModel = GitDiffModel(directory: session.rootDirectory, selectedFile: session.fileBrowser.selectedFile,
                                     remote: session.remoteGit)
        }
    }
}
