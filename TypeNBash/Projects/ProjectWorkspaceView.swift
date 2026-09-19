import SwiftUI

/// Lives for one project. Editor, comparison and console state end with it.
struct ProjectWorkspaceView: View {
    let session: WindowSession
    @State private var editorSession = EditorSession()
    @State private var terminalController = TerminalController()
    @State private var diffModel: GitDiffModel?
    @State private var showsSourceControl = false
    @State private var hideConsole = false

    var body: some View {
        CanvasView(windowSession: session, terminalController: terminalController, onOpenInTerminal: { hideConsole = false }) {
            ProjectSplitView(hideConsole: $hideConsole) {
                Group {
                    if let diffModel {
                        GitDiffView(model: diffModel, showsFooter: false)
                    } else {
                        WorkspaceEditorPane(model: session.fileBrowser, session: editorSession, showsFooter: false)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 120, maxHeight: .infinity)

            } footer: {
                Group {
                    if let diffModel {
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
        }
        .toolbar {
            ToolbarItem {
                Button {
                    showsSourceControl = true
                } label: {
                    Label("Source Control", image: "vault.symbols.2")
                }
                .disabled(session.location != .local)
                .help("Source control for this project")
            }
            ToolbarItem {
                Button(action: toggleDiffs) {
                    Label("Changes", systemImage: "arrow.left.arrow.right")
                }
                .disabled(session.location != .local)
                .help(diffModel == nil ? "Compare saved Git changes" : "Return to the editor")
            }
        }
        .sheet(isPresented: $showsSourceControl) {
            SourceControlView(directory: session.rootDirectory)
        }
        .task(id: diffModel.map { ObjectIdentifier($0) }) {
            await diffModel?.refresh()
        }
        .onChange(of: session.terminalGeneration) {
            diffModel = nil
            showsSourceControl = false
        }
    }

    private func toggleDiffs() {
        if diffModel != nil {
            diffModel = nil
        } else {
            diffModel = GitDiffModel(directory: session.rootDirectory, selectedFile: session.fileBrowser.selectedFile)
        }
    }
}
