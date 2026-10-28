import SwiftUI
import BibTeXKit
import BibTeXViewer


struct WorkspacePane: View {
    let model: FileBrowserModel
    var bibliography: BibLibrary? = nil
    @State var session = EditorSession()
    var showsFooter = true
    /// Present only where a console is mounted, which is project mode.
    var onRunInConsole: ((String) -> Void)?
    /// Lives here because both the header (which toggles it) and the viewer
    /// (which renders it) hang off this pane.
    @State private var mdViewSelection: MDViewStyle = .fancy
    @State private var showsBrowser = false
    /// Created on first show and kept, so tabs survive toggling back to the editor.
    @State private var browserModel: BrowserModel?

    var body: some View {
        Group {
            if showsBrowser, let browserModel {
                // The browser pane brings its own header; the toggle sits at the
                // same trailing edge as in the editor header.
                BrowserView(model: browserModel) {
                    BrowserToggleButton(showsBrowser: $showsBrowser)
                }
            } else {
                FileViewer(model: model, session: session, mdViewSelection: mdViewSelection, bibliography: bibliography)
                    .paneBar(.top) { editorHeader }
                    .paneBar(.bottom) {
                        if showsFooter && !model.isReadOnly {
                            PaneBar(edge: .bottom) {
                                Text(session.position)
                                Spacer()
                                EditorIndentationLabel()
                            }
                        }
                    }
                    .onChange(of: showsBrowser) { _, shows in
                        if shows && browserModel == nil { browserModel = BrowserModel() }
                    }
            }
        }
        .onChange(of: session.sourceNavigation?.id) {
            if session.sourceNavigation != nil { showsBrowser = false; mdViewSelection = .plain }
        }
    }

    /// Languages whose consoles take pasted source.
    private var isScript: Bool {
        ["r", "py"].contains(model.selectedFile?.pathExtension.lowercased() ?? "")
    }

    private var isTable: Bool {
        if case .table = model.preview { return true }
        return false
    }


    private var editorHeader: some View {
        PaneBar {
            if model.isReadOnly {
                ReadOnlyBadge()
            } else {
                EditorSaveButton(model: model, session: session)
            }
            Spacer()
            EditorDocumentTitle(model: model, session: session)
            Spacer()
            EditorDocumentKindLabel(model: model, session: session)
            if case .markdown = model.preview {
                MarkdownViewPicker(selection: $mdViewSelection)
            }
            if case .table = model.preview {
                TableDataMenu(session: session)
            }
            if let onRunInConsole, isScript {
                RunInConsoleButton(session: session, run: onRunInConsole)
            }
            if !model.isReadOnly, !isTable {
                EditorOutlineMenu(session: session)
                EditorFindButton(session: session)
                EditorActionsMenu(session: session)
            }
            BrowserToggleButton(showsBrowser: $showsBrowser)
                .buttonStyle(.borderedProminent)
                .tint(.blue)
        } accessory: {
            // Stays mounted while hidden: it is what answers ⌘F.
            if !model.isReadOnly {
                EditorFindBar(session: session)
            }
        }
    }
}

struct TerminalPane: View {
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


