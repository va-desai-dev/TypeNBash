//
//  EditorBarItems.swift
//  TypeNBash
//
//  The individual controls that go in an editor pane's `PaneBar`s. Each one
//  takes only what it reads; which ones appear for which document is decided
//  where the bar is assembled, not here.
//

import AppKit
import Defaults
import SwiftUI
import SyntaxFormat
import SyntaxParsers
internal import URLUtils

// MARK: - Document

/// Saves the open file, or asks for a name first when it is untitled.
struct EditorSaveButton: View {
    let model: FileBrowserModel
    /// The same session `FileViewer` hands to its text view; a pending CSV cell
    /// edit is committed through it before saving.
    let session: EditorSession

    @State private var isSavingNewFile = false
    @State private var newFileName = ""
    @State private var newFileExtension = "txt"

    var body: some View {
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
    }
}

/// Stands in for the save button on documents that can't be edited.
struct ReadOnlyBadge: View {
    var body: some View {
        Label("Read Only", systemImage: "eye")
            .foregroundStyle(.secondary)
    }
}

/// File name, unsaved-changes dot, and the last save error.
struct EditorDocumentTitle: View {
    let model: FileBrowserModel
    let session: EditorSession

    private var title: String {
        model.selectedFile?.lastPathComponent ?? (model.isUntitled ? "Untitled" : "Preview")
    }

    var body: some View {
        if model.hasUnsavedChanges || session.hasPendingCSVEdit {
            Circle().fill(Color.orange)
                .frame(width: 6, height: 6)
                .help("Unsaved changes")
        }
        Text(title.deletingPathExtension)
            .lineLimit(1)
        if let saveError = model.saveError {
            Text(saveError)
                .foregroundStyle(Color.red)
        }
    }
}

/// The syntax the editor is using, or the kind of preview.
struct EditorDocumentKindLabel: View {
    let model: FileBrowserModel
    let session: EditorSession

    var body: some View {
        Text(
            model.isReadOnly ? model.readOnlyLabel : session.syntaxController?.syntaxName ?? "Plain Text"
        )
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// Switches a markdown file between the rendered view and the code editor.
struct MarkdownViewPicker: View {
    @Binding var selection: MDViewStyle

    var body: some View {
        Picker("Markdown View", selection: $selection) {
            Image(systemName: "doc.richtext")
                .help("Formatted markdown")
                .tag(MDViewStyle.fancy)
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .help("Markdown source in the code editor")
                .tag(MDViewStyle.plain)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// Copies the table grid, with its edits and column headers, as CSV.
struct TableDataMenu: View {
    let session: EditorSession

    @State private var error: String?

    var body: some View {
        Menu("Data") {
            Button("Copy All Rows as CSV") { copyCSV(scope: .allRows) }
            Button("Copy Filtered Rows as CSV") { copyCSV(scope: .visibleRows) }
        }
        .help("Copy the current edited table, including column headers")
        .alert("Couldn’t Prepare CSV", isPresented: Binding(
            get: { error != nil }, set: { if !$0 { error = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(error ?? "") }
    }

    private func copyCSV(scope: CSVAnalysisSnapshot.Scope) {
        do {
            let snapshot = try session.csvAnalysisSnapshot(scope: scope)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(snapshot.csvText, forType: .string)
        } catch { self.error = error.localizedDescription }
    }
}

/// Sends the selection, or the cell the caret is in, to the console.
struct RunInConsoleButton: View {
    let session: EditorSession
    let run: (String) -> Void

    var body: some View {
        Button {
            guard let snippet = session.consoleSnippet() else { return }
            // A trailing newline is what makes the console execute it rather
            // than leave it sitting at the prompt.
            run(snippet.hasSuffix("\n") ? snippet : snippet + "\n")
        } label: {
            Image(systemName: "play")
        }
        .help("Run the selection, or the cell the caret is in, in the console (⌃⏎)")
        .accessibilityLabel("Run in Console")
        .keyboardShortcut(.return, modifiers: .control)
    }
}

// MARK: - Text editing

struct EditorOutlineMenu: View {
    let session: EditorSession

    var body: some View {
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

struct EditorFindButton: View {
    let session: EditorSession

    var body: some View {
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
    }
}

struct EditorActionsMenu: View {
    let session: EditorSession

    var body: some View {
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
}

struct EditorOptionsMenu: View {
    var body: some View {
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
}

// MARK: - Footer

/// Current indentation setting, shared by every editor.
struct EditorIndentationLabel: View {
    @AppStorage(.editorUsesSpaces) private var usesSpaces: Bool
    @AppStorage(.editorTabWidth) private var tabWidth: Int

    var body: some View {
        Text(usesSpaces ? "Spaces: \(tabWidth)" : "Tabs: \(tabWidth)")
    }
}
