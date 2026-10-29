//
//  SnippetStoreView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/29/26.
//

import SwiftUI

struct SnippetsTab: View {
    let store: SnippetsStore
    /// Types a snippet into this window's console. Supplied by the workspace,
    /// which owns the terminal.
    let onRun: (String) -> Void
    /// The snippet being edited in the sheet; a new one is only saved on Save.
    @Binding var editing: Snippet?

    var body: some View {
        Group {
            if store.snippets.isEmpty {
                ContentUnavailableView(
                    "No Snippets",
                    systemImage: "apple.terminal",
                    description: Text("Save commands you run often, then send them to the terminal.")
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(store.snippets) { snippet in
                            MacColumnRowButton(
                                action: { store.select(snippet.id) },
                                name: snippet.name,
                                placeholder: "Untitled Snippet",
                                subtitle: snippet.code,
                                isSelected: store.selectedSnippet == snippet.id) {
                                    Button("Run in Terminal") { run(snippet) }
                                        .disabled(snippet.commandLine == nil)
                                    Button("Copy") { copy(snippet) }
                                    Button("Edit…") { editing = snippet }
                                    Divider()
                                    Button("Delete", role: .destructive) { store.delete(snippet) }
                                }
                        }
                    }
                    .padding(8)
                }
                .scrollContentBackground(.hidden)
            }
        }
        .sheet(item: $editing) { snippet in
            SnippetEditorSheet(snippet: snippet) { store.save($0) }
        }
    }

    private func run(_ snippet: Snippet) {
        store.select(snippet.id)
        guard let command = snippet.commandLine else { return }
        onRun(command)
    }

    private func copy(_ snippet: Snippet) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet.code, forType: .string)
    }
}

/// The snippets tab's bottom bar: add, and run the selection.
struct SnippetsBarItems: View {
    let store: SnippetsStore
    let onRun: (String) -> Void
    @Binding var editing: Snippet?

    private var selected: Snippet? {
        store.snippets.first { $0.id == store.selectedSnippet }
    }

    var body: some View {
        Button {
            editing = Snippet(id: UUID(), name: "", code: "", isSudo: false)
        } label: {
            Label("New Snippet", systemImage: "plus")
        }
        .help("New snippet")
        Spacer()
        Button {
            if let command = selected?.commandLine { onRun(command) }
        } label: {
            Label("Run", systemImage: "play.fill")
        }
        .help("Run the selected snippet in the terminal")
        .disabled(selected?.commandLine == nil)
    }
}

private struct SnippetEditorSheet: View {
    @State private var draft: Snippet
    let onSave: (Snippet) -> Void
    @Environment(\.dismiss) private var dismiss



    init(snippet: Snippet, onSave: @escaping (Snippet) -> Void) {
        _draft = State(initialValue: snippet)
        self.onSave = onSave
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Name", text: $draft.name, prompt: Text("Untitled Snippet"))
                .lineLimit(1)
                .padding(.vertical, 10)
                .padding(.horizontal, 6)
                .textFieldStyle(.plain)
                .writingToolsBehavior(.disabled)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            TextEditor(text: $draft.code)
                .padding(.horizontal, 6)
                .padding(.vertical, 10)
                .textEditorStyle(.plain)
                .font(.system(.body, design: .monospaced))
                .autocorrectionDisabled()
                .writingToolsBehavior(.disabled)
                .frame(minHeight: 160)
                .background(Color.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            Toggle("Run with sudo", isOn: $draft.isSudo)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    onSave(draft)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .scrollContentBackground(.hidden)
        .padding(20)
        .frame(width: 460)
        .presentationBackground(AppTheme.shared.windowBackground)
    }
}
