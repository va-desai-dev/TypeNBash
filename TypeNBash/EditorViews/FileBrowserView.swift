import AppKit
import SwiftUI
import PDFKit


/// Finder-style pane beside the console. Works for both the local and SSH
/// Workspace filesystems since it talks only to `FileBrowserModel`.
struct FileBrowserView: View {
    @Bindable var model: FileBrowserModel
    /// Whether the workspace is local (enables app-open / reveal actions).
    var isLocal = true

    /// Requests that the console cd to this entry's directory.
    var onOpenInTerminal: (WorkspaceFileEntry) -> Void = { _ in }


    var body: some View {
        FileBrowserList(
            entries: model.entries,
            selection: model.selectedFile,
            isLocal: isLocal,
            onSelect: model.select,
            onOpenInTerminal: onOpenInTerminal
        )
        .overlay { listOverlay }
    }

    @ViewBuilder var listOverlay: some View {
        if let error = model.errorMessage {
            ContentUnavailableView(
                "Folder Unavailable",
                systemImage: "folder.badge.questionmark",
                description: Text(error)
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if model.entries.isEmpty && !model.isLoading {
            ContentUnavailableView("Empty Folder", systemImage: "folder")
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }
}

/// Header row above the file list with navigation and file-creation actions.
struct FileBrowserToolbar: View {
    @Bindable var model: FileBrowserModel
    @Binding var isNamingFolder: Bool
    @Binding var newFolderName: String

    var body: some View {
        HStack {
            ControlGroup {
                Button { model.goBack() } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!model.canGoBack)
                .help("Back")
                Button { model.goUp() } label: {
                    Image(systemName: "smallcircle.filled.circle")
                }
                .disabled(!model.canGoUp)
                .help("Enclosing folder")
                Button { model.goForward() } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!model.canGoForward)
                .help("Forward")
            }
            .controlSize(.regular)

            Spacer()

            ControlGroup {
                Toggle(isOn: $model.showsHiddenFiles) {
                    if model.showsHiddenFiles {
                        Label {
                            Text("Showing Hidden Files")
                        } icon: {
                            Image(systemName: "eye.slash")
                        }
                    } else {
                        Label {
                            Text("Show Hidden Files")
                        } icon: {
                            Image(systemName: "eye")
                        }
                    }
                }
                .help("Show hidden files")
                Button("Refresh", systemImage: "arrow.clockwise") {
                    model.refresh()
                }
                .help("Refresh")

                Button("New Folder", systemImage: "folder.badge.plus") {
                    newFolderName = "untitled folder"
                    isNamingFolder = true
                }
                .help("New Folder")
                Button("New File", systemImage: "doc.badge.plus") {
                    model.newFile()
                }
                .help("New File")
            }
            .controlSize(.regular)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }
}

struct FileViewer: View {
    @Bindable var model: FileBrowserModel
    /// Owned by the enclosing SwiftUI view and shared with the header and
    /// footer, which drive and read this editor's text view.
    let session: EditorSession

    @AppStorage("editor.showsInvisibles") private var showsInvisibles = true
    @AppStorage("editor.showsIndentGuides") private var showsIndentGuides = true
    @AppStorage("editor.showsLineNumbers") private var showsLineNumbers = true
    @AppStorage("editor.wrapsLines") private var wrapsLines = true
    @AppStorage("editor.automaticCompletion") private var automaticCompletion = true
    @AppStorage("editor.usesSpaces") private var usesSpaces = true
    @AppStorage("editor.tabWidth") private var tabWidth = 4


    var body: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var options: EditorOptions {
        EditorOptions(showsInvisibles: showsInvisibles, showsIndentGuides: showsIndentGuides,
                      showsLineNumbers: showsLineNumbers, wrapsLines: wrapsLines,
                      automaticCompletion: automaticCompletion, usesSpaces: usesSpaces,
                      tabWidth: [2, 4, 8].contains(tabWidth) ? tabWidth : 4)
    }


    @ViewBuilder private var previewContent: some View {
        switch model.preview {
            case .text(let contents):
                CodeEditorTextView(
                    text: Binding(
                    get: { contents },
                    set: { model.updatePreviewText($0) }
                ),
                    fileURL: model.selectedFile, options: options, session: session)
                // Each file gets a fresh editor, grammar, and undo stack.
                .id(model.selectedFile)

            case .table(let table):
                CSVPreviewView(table: table, onEdit: model.updatePreviewTable)
                    // Each file gets a fresh grid, the way each file gets a
                    // fresh editor above.
                    .id(model.selectedFile)

            case .unsupported(let message):
                ContentUnavailableView {
                    Text(message).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))
                .background(Color.card)
            case .failed(let error):
                ContentUnavailableView {
                    Text(error).foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))
                .background(Color.card)

            case .none:
                ContentUnavailableView {
                    Text("Select a file to preview")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))
                .background(Color.card)
            case .document(let data):
                DocumentPreviewView(data: data)
                    .id(model.selectedFile)
            case .image(let data):
                ImagePreviewView(data: data)
                    .id(model.selectedFile)
        }
    }
}

struct ImagePreviewView: View {
    /// Raw image bytes — works for both local and SSH previews.
    let data: Data

    var body: some View {
        if let nsImage = NSImage(data: data) {
            Image(nsImage: nsImage)
                .resizable()
                .scaledToFit()
                .padding()
        } else {
            ContentUnavailableView("Unable to load image",
                                   systemImage: "photo.badge.exclamationmark")
        }
    }
}

struct PDFKitPreviewView: NSViewRepresentable {
    /// Raw PDF bytes — works for both local and SSH previews.
    let data: Data

    func makeNSView(context: Context) -> PDFView {
        let pdfView = PDFView()
        pdfView.document = PDFDocument(data: data)
        pdfView.autoScales = true
        return pdfView
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        // The call site keys this view by file (`.id`), so a new file rebuilds the
        // view instead of mutating an existing document here.
    }
}

struct DocumentPreviewView: View {
    let data: Data
    var body: some View {
        PDFKitPreviewView(data: data)
    }
}

