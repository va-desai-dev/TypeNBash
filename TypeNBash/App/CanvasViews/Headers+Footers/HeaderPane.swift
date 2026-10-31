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
            Label("Save", systemImage: "checkmark")
        }
        .buttonStyle(.glassButton)
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
        Toggle(isOn: Binding(get: {
            selection == .fancy
        }, set: {
            selection = $0 ? .fancy : .plain
        })) {
            Label(
                selection == .fancy ? "Formatted" : "Source",
                systemImage: selection == .fancy ? "eye" : "chevron.left.forwardslash.chevron.right"
            )
            .labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .buttonStyle(.glassSegment)
    }
}

/// Copies the table grid, with its edits and column headers, as CSV.
struct TableDataMenu<S: ButtonStyle>: View {
    let session: EditorSession
    let style: S

    @State private var error: String?

    var body: some View {
        Menu {
            Button("Copy All Rows as CSV") { copyCSV(scope: .allRows) }
            Button("Copy Filtered Rows as CSV") { copyCSV(scope: .visibleRows) }
        } label: {
            Label("Copy Data", systemImage: "document.on.document.fill")
                .labelStyle(.iconOnly)
        }
        .menuStyle(.button)
        .buttonStyle(style)
        .menuIndicator(.hidden)
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
        .buttonStyle(.glassSegment)
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
        .menuStyle(.button)
        .buttonStyle(.glassSegment)
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
        .buttonStyle(.glassSegment)
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
        .menuStyle(.button)
        .buttonStyle(.glassSegment)
        .help("Editor Actions")
        .accessibilityLabel("Editor Actions")
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

struct GlassButtonLabelStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 26, height: 26)
            .glassEffect(.regular, in: .circle)
    }
}

struct GlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(GlassButtonLabelStyle())
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
    }
}

extension ButtonStyle where Self == GlassButtonStyle {
    static var glassButton: GlassButtonStyle { GlassButtonStyle() }
}



struct GlassControlGroupButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(enabled ? Color.foreground : Color.secondary)
            .labelStyle(.iconOnly)
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .font(.system(size: 14, weight: .semibold))
            .frame(width: 26, height: 26)
            .opacity(configuration.isPressed ? 0.7 : 1.0)
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
    }
}

extension ButtonStyle where Self == GlassControlGroupButtonStyle {
    static var glassSegment: GlassControlGroupButtonStyle { GlassControlGroupButtonStyle() }
}

/// Icon controls fused into one Liquid Glass capsule with hairlines between
/// them, the way Pages and Notes group their editing controls. One glass
/// shape for the whole strip: per-item unions re-materialize every time a
/// control comes or goes, which is what made the bar assemble a piece at a time.
struct DynamicLiquidGlassStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        Group(subviews: content) { subviews in
            HStack(spacing: 0) {
                ForEach(subviews) { subview in
                    subview
                    if subview.id != subviews.last?.id {
                        Rectangle()
                            .fill(Color(nsColor: .separatorColor).opacity(0.4))
                            .frame(width: 0.5, height: 14)
                    }
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 26)
        .glassEffect(.regular, in: .capsule)
        // The set of controls follows the open document; when it changes the
        // capsule should snap to its new width, not tween through each step.
        .transaction { $0.animation = nil }
    }
}
