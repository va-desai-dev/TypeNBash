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
    /// What the header's controls are laid out for. Opening a file blanks
    /// `preview` until the read lands, so this holds the previous document's
    /// layout through that gap and the bar changes once per file, not once
    /// per loading step.
    @State private var headerKind: HeaderKind = .text

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
                    .paneBar(.top) {
                        switch headerKind {
                            case .markdown: editorHeader
                            case .text: editorHeader
                            case .table: csvHeaderItems
                            case .readOnly: previewHeader
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
        .onChange(of: HeaderKind(model), initial: true) { _, kind in
            if let kind { headerKind = kind }
        }
    }

    enum HeaderKind: Equatable {
        case text, markdown, table, readOnly

        /// Nil while the file is still loading.
        init?(_ model: FileBrowserModel) {
            switch model.preview {
                case .none: return nil
                case .markdown: self = .markdown
                case .table: self = .table
                default: self = model.isReadOnly ? .readOnly : .text
            }
        }
    }

    /// Languages whose consoles take pasted source.
    private var isScript: Bool {
        ["r", "py"].contains(model.selectedFile?.pathExtension.lowercased() ?? "")
    }

    private var csvHeaderItems: some View {
        PaneBar {
            EditorSaveButton(model: model, session: session)
            Spacer()
            EditorDocumentTitle(model: model, session: session)
            Spacer()
            TableDataMenu(session: session, style: .glassButton)
            BrowserToggleButton(showsBrowser: $showsBrowser)
                .buttonStyle(.glassButton)
        }
    }

    private var previewHeader: some View {
        PaneBar {
            ReadOnlyBadge()
            Spacer()
            EditorDocumentTitle(model: model, session: session)
            Spacer()
            BrowserToggleButton(showsBrowser: $showsBrowser)
                .buttonStyle(.glassButton)
        }
    }

    private var editorHeader: some View {
        PaneBar {
            EditorSaveButton(model: model, session: session)
            Spacer()
            EditorDocumentTitle(model: model, session: session)
            Spacer()
            DynamicLiquidGlassStrip {
                if headerKind == .markdown {
                    MarkdownViewPicker(selection: $mdViewSelection)
                }
                if let onRunInConsole, isScript {
                    RunInConsoleButton(session: session, run: onRunInConsole)
                }
                EditorOutlineMenu(session: session)
                EditorActionsMenu(session: session)
            }
            BrowserToggleButton(showsBrowser: $showsBrowser)
                .buttonStyle(.glassButton)
        } accessory: {
            EditorFindBar(session: session)
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


