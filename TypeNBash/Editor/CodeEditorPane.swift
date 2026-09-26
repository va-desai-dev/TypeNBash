import AppKit
import Defaults
import SwiftUI
import SyntaxFormat
import SyntaxParsers
internal import URLUtils

struct FileBrowserPaneHeader: View {
    @Bindable var model: FileBrowserModel

    /// The same session `FileViewer` hands to its `CodeEditorTextView`. The
    /// editor actions below reach the text view only through this object, so a
    /// header with its own session would render but do nothing.
    let session: EditorSession

    /// Sends a snippet to the workspace console. Absent outside project mode,
    /// where there is no console mounted to send it to.
    var onRunInConsole: ((String) -> Void)?

    @State private var analysisError: String?
    @State private var isSavingNewFile = false
    @State private var newFileName = ""
    @State private var newFileExtension = "txt"
    var fileURL: URL?

    private var title: String {
        model.selectedFile?.lastPathComponent ?? (model.isUntitled ? "Untitled" : "Preview")
    }

    /// Languages whose consoles take pasted source. The run action is pointless
    /// for anything else.
    private var isScript: Bool {
        ["r", "py"].contains(model.selectedFile?.pathExtension.lowercased() ?? "")
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                if model.isSaving {
                    ProgressView().controlSize(.small)
                }
                Button {
                    session.csvGrid?.commitEditingIfNeeded()
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
                .buttonStyle(.bordered)
                .labelStyle(.titleOnly)
                .keyboardShortcut("s", modifiers: .command)
                .disabled((!model.hasUnsavedChanges && !session.hasPendingCSVEdit) || model.isPreviewTruncated || model.isSaving)
                .help(model.isPreviewTruncated ? "File truncated — cannot save" : "Save (⌘S)")
                Spacer()
                if model.hasUnsavedChanges || session.hasPendingCSVEdit {
                    Circle().fill(Color.orange)
                        .frame(width: 6, height: 6)
                        .help("Unsaved changes")
                }
                Text(title.deletingPathExtension)
                    .lineLimit(1)
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
                        .foregroundStyle(Color.red)
                }
                Spacer()
                Text(session.syntaxController?.syntaxName ?? "Plain Text")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if case .table = model.preview {
                    Menu("Data") {
                        Button("Copy All Rows as CSV") { copyCSV(scope: .allRows) }
                        Button("Copy Filtered Rows as CSV") { copyCSV(scope: .visibleRows) }
                    }
                    .help("Copy the current edited table, including column headers")
                    .alert("Couldn’t Prepare CSV", isPresented: Binding(
                        get: { analysisError != nil }, set: { if !$0 { analysisError = nil } }
                    )) {
                        Button("OK", role: .cancel) { }
                    } message: { Text(analysisError ?? "") }
                }
                if let onRunInConsole, isScript {
                    Button {
                        guard let snippet = session.consoleSnippet() else { return }
                        // A trailing newline is what makes the console execute
                        // it rather than leave it sitting at the prompt.
                        onRunInConsole(snippet.hasSuffix("\n") ? snippet : snippet + "\n")
                    } label: {
                        Image(systemName: "play")
                    }
                    .help("Run the selection, or the cell the caret is in, in the console (⌃⏎)")
                    .accessibilityLabel("Run in Console")
                    .keyboardShortcut(.return, modifiers: .control)
                }
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
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            if !session.isFindBarPresented {
                Divider()
            }
            EditorFindBar(session: session)
        }
        .background(Color.card)
    }
    private func copyCSV(scope: CSVAnalysisSnapshot.Scope) {
        do {
            let snapshot = try session.csvAnalysisSnapshot(scope: scope)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.csvText, forType: .string)
        } catch { analysisError = error.localizedDescription }
    }

    private var optionsMenu: some View {
        Menu {
            EditorOptionsControls()
        } label: {
            Image(systemName: "slider.horizontal.3")
        }
        .menuStyle(.borderedButton)
        .menuIndicator(.hidden)
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
        .menuStyle(.borderedButton)
        .menuIndicator(.hidden)
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
        .menuStyle(.borderedButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Jump to Symbol")
        .accessibilityLabel("Jump to Symbol")
    }
}

struct FileViewerFooter: View {
    var showsSeparator = true
    /// Shared with `FileViewer`; `position` is pushed here by the text view's
    /// coordinator on every selection change.
    let session: EditorSession

    @AppStorage(.editorUsesSpaces) private var usesSpaces: Bool
    @AppStorage(.editorTabWidth) private var tabWidth: Int

    var body: some View {
        VStack(spacing: 0) {
            if showsSeparator { Divider() }
            HStack(alignment: .center)  {
                Text(session.position)
                Spacer()
                Text(usesSpaces ? "Spaces: \(tabWidth)" : "Tabs: \(tabWidth)")

            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
        }
    }
}
/// The editor options shared by every editor. The same controls sit in each
/// editor's options menu and in the Settings window; both write the same
/// user defaults, so a change in either place reaches every open editor.
struct EditorOptionsControls: View {
    @AppStorage(.editorShowsInvisibles) private var showsInvisibles: Bool
    @AppStorage(.editorShowsIndentGuides) private var showsIndentGuides: Bool
    @AppStorage(.editorShowsLineNumbers) private var showsLineNumbers: Bool
    @AppStorage(.editorShowsChanges) private var showsChanges: Bool
    @AppStorage(.editorWrapsLines) private var wrapsLines: Bool
    @AppStorage(.editorAutomaticCompletion) private var automaticCompletion: Bool
    @AppStorage(.editorUsesSpaces) private var usesSpaces: Bool
    @AppStorage(.editorTabWidth) private var tabWidth: Int

    var body: some View {
        Form {
            Section("Editor View") {
                Toggle("Show Invisibles", isOn: $showsInvisibles)
                Toggle("Show Indent Guides", isOn: $showsIndentGuides)
                Toggle("Show Line Numbers", isOn: $showsLineNumbers)
            }
            Section("Text & Lines") {
                Toggle("Show Changes", isOn: $showsChanges)
                Toggle("Wrap Lines", isOn: $wrapsLines)
                Toggle("Automatic Word Completion", isOn: $automaticCompletion)
                Toggle("Indent Using Spaces", isOn: $usesSpaces)
                Picker("Indent Width", selection: $tabWidth) {
                    Text("2").tag(2)
                    Text("4").tag(4)
                    Text("8").tag(8)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}

