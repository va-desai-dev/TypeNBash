import SwiftUI

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
        .frame(minWidth: 860, minHeight: 560)
    }
}

private struct FreeWorkspaceView: View {
    let session: WindowSession
    @State private var terminalController = TerminalController()
    @State private var selectedViewMode = ViewMode.terminal

    var body: some View {
        CanvasView(windowSession: session, terminalController: terminalController,
                   onOpenInTerminal: { selectedViewMode = .terminal }) {
            ZStack {
                WorkspaceTerminalPane(session: session, controller: terminalController)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .opacity(selectedViewMode == .terminal ? 1 : 0)
                    .allowsHitTesting(selectedViewMode == .terminal)
                    .accessibilityHidden(selectedViewMode != .terminal)

                if selectedViewMode != .terminal {
                    WorkspaceEditorPane(model: session.fileBrowser)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
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

enum ViewMode: CaseIterable, Identifiable, Hashable, Sendable {
    var id: Self { self }
    case terminal
    case previewMode
}
