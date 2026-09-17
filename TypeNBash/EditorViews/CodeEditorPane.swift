import AppKit
import SwiftUI
import SyntaxFormat
import SyntaxParsers

struct FileBrowserPaneHeader: View {
    @Bindable var model: FileBrowserModel

    /// The same session `FileViewer` hands to its `CodeEditorTextView`. The
    /// editor actions below reach the text view only through this object, so a
    /// header with its own session would render but do nothing.
    let session: EditorSession

    @State private var isSavingNewFile = false
    @State private var newFileName = ""
    @State private var newFileExtension = "txt"
    var fileURL: URL?

    @AppStorage("editor.showsInvisibles") private var showsInvisibles = true
    @AppStorage("editor.showsIndentGuides") private var showsIndentGuides = true
    @AppStorage("editor.showsLineNumbers") private var showsLineNumbers = true
    @AppStorage("editor.wrapsLines") private var wrapsLines = true
    @AppStorage("editor.automaticCompletion") private var automaticCompletion = true
    @AppStorage("editor.usesSpaces") private var usesSpaces = true
    @AppStorage("editor.tabWidth") private var tabWidth = 4

    private var title: String {
        model.selectedFile?.lastPathComponent ?? (model.isUntitled ? "Untitled" : "Preview")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                if model.hasUnsavedChanges {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if model.isSaving {
                    ProgressView().controlSize(.small)
                }
                Button {
                    if model.isUntitled {
                        newFileName = ""
                        newFileExtension = "txt"
                        isSavingNewFile = true
                    } else {
                        model.save()
                    }
                } label: {
                    Label("Save", systemImage: "square.and.arrow.down")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.hasUnsavedChanges || model.isPreviewTruncated)
                .help(model.isPreviewTruncated ? "File truncated — cannot save" : "Save (⌘S)")
                .alert("Save New File", isPresented: $isSavingNewFile) {
                    TextField("File name", text: $newFileName)
                    TextField("Extension", text: $newFileExtension)
                    Button("Save") {
                        let name = newFileName
                        let ext = newFileExtension
                        Task { _ = await model.saveNewFile(named: name, extension: ext) }
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Choose a name and extension. Leaving the extension blank saves as “.txt”.")
                }
                if let saveError = model.saveError {
                    Text(saveError)
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 10)
                        .padding(.bottom, 6)
                }
                Spacer()
                Text(session.syntaxController?.syntaxName ?? "Plain Text")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                outlineMenu
                Button {
                    if session.isFindBarPresented {
                        session.dismissFind()
                    } else {
                        session.find()
                    }
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .help("Find and Replace (⌘F)")
                .accessibilityLabel("Find and Replace")
                editMenu
                optionsMenu
            }
            Divider()
                .padding(.top, 6)
            // Hangs off the bottom of the header so the find bar sits between
            // the toolbar rows and the text. Always mounted — it is also what
            // listens for ⌘F coming from inside the text view.
            EditorFindBar(session: session)
        }
        .background(Color.card)
    }
    private var optionsMenu: some View {
        Menu {
            Toggle("Show Invisibles", isOn: $showsInvisibles)
            Toggle("Show Indent Guides", isOn: $showsIndentGuides)
            Toggle("Show Line Numbers", isOn: $showsLineNumbers)
            Toggle("Wrap Lines", isOn: $wrapsLines)
            Divider()
            Toggle("Automatic Word Completion", isOn: $automaticCompletion)
            Toggle("Indent Using Spaces", isOn: $usesSpaces)
            Picker("Indent Width", selection: $tabWidth) {
                Text("2").tag(2)
                Text("4").tag(4)
                Text("8").tag(8)
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Editor Options")
        .accessibilityLabel("Editor Options")
    }
    private var editMenu: some View {
        Menu {
            Button("Complete Word (⌃Space)") { session.perform(#selector(NSTextView.complete(_:))) }
            Button("Toggle Comment (⌘/)") { session.perform(#selector(EditorTextView.toggleComment(_:))) }
                .disabled(session.syntaxController?.syntax.commentDelimiters.isEmpty ?? true)
            Divider()
            Button("Indent (⌘])") { session.perform(#selector(EditorTextView.shiftRight(_:))) }
            Button("Outdent (⌘[)") { session.perform(#selector(EditorTextView.shiftLeft(_:))) }
            Button("Move Line Up (⌥⌘↑)") { session.perform(#selector(EditorTextView.moveLineUp(_:))) }
            Button("Move Line Down (⌥⌘↓)") { session.perform(#selector(EditorTextView.moveLineDown(_:))) }
            Button("Duplicate Line") { session.perform(#selector(EditorTextView.duplicateLine(_:))) }
            Button("Delete Line") { session.perform(#selector(EditorTextView.deleteLine(_:))) }
            Divider()
            Button("Split Selection into Cursors") { session.perform(#selector(EditorTextView.splitSelectionByLines(_:))) }
            Button("Select Enclosing Brackets") { session.perform(#selector(EditorTextView.selectEnclosingSymbols(_:))) }
            Button("Trim Trailing Whitespace") { session.perform(#selector(EditorTextView.trimTrailingWhitespace(_:))) }
            Divider()
            Button("Increase Font Size") { session.perform(#selector(EditorTextView.biggerFont(_:))) }
            Button("Decrease Font Size") { session.perform(#selector(EditorTextView.smallerFont(_:))) }
            Button("Reset Font Size") { session.perform(#selector(EditorTextView.resetFont(_:))) }
        } label: {
            Image(systemName: "curlybraces")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Editor Actions")
        .accessibilityLabel("Editor Actions")
    }
    private var outlineMenu: some View {
        Menu {
            let items = session.syntaxController?.outlineItems ?? []
            if items.isEmpty {
                Text("No symbols in this file")
            } else {
                ForEach(items) { item in
                    if item.isSeparator {
                        Divider()
                    } else {
                        Button(item.title) { session.select(item.range) }
                    }
                }
            }
        } label: {
            Image(systemName: "list.bullet.indent")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Jump to Symbol")
        .accessibilityLabel("Jump to Symbol")
    }
}

struct FileViewerFooter: View {
    /// Shared with `FileViewer`; `position` is pushed here by the text view's
    /// coordinator on every selection change.
    let session: EditorSession

    @AppStorage("editor.usesSpaces") private var usesSpaces = true
    @AppStorage("editor.tabWidth") private var tabWidth = 4

    var body: some View {
        VStack {
            Divider()
            HStack {
                Text(session.position)
                Spacer()
                Text(usesSpaces ? "Spaces: \(tabWidth)" : "Tabs: \(tabWidth)")
            }
        }
    }
}


