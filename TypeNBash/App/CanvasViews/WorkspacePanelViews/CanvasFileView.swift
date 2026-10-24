//
//  FileViewer.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//
import AppKit
import Defaults
import SwiftUI
import BibTeXViewer
import MarkdownEngine

struct FileViewer: View {
    @Bindable var model: FileBrowserModel
    /// Owned by the enclosing SwiftUI view and shared with the header and
    /// footer, which drive and read this editor's text view.
    let session: EditorSession
    /// Whether `.md` files render formatted or open in the code editor.
    var mdViewSelection: MDViewStyle = .fancy
    var bibliography: BibLibrary? = nil

    @AppStorage(.editorShowsInvisibles) private var showsInvisibles: Bool
    @AppStorage(.editorShowsIndentGuides) private var showsIndentGuides: Bool
    @AppStorage(.editorShowsLineNumbers) private var showsLineNumbers: Bool
    @AppStorage(.editorShowsChanges) private var showsChanges: Bool
    @AppStorage(.editorWrapsLines) private var wrapsLines: Bool
    @AppStorage(.editorAutomaticCompletion) private var automaticCompletion: Bool
    @AppStorage(.editorUsesSpaces) private var usesSpaces: Bool
    @AppStorage(.editorTabWidth) private var tabWidth: Int



    var body: some View {
        previewContent
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                model.refreshEditorGitBaseline()
            }
            .onReceive(NotificationCenter.default.publisher(for: .editorGitBaselineDidChange)) { _ in
                model.refreshEditorGitBaseline()
            }
    }

    private var options: EditorOptions {
        EditorOptions(showsInvisibles: showsInvisibles, showsIndentGuides: showsIndentGuides,
                      showsLineNumbers: showsLineNumbers, wrapsLines: wrapsLines,
                      automaticCompletion: automaticCompletion, usesSpaces: usesSpaces,
                      tabWidth: [2, 4, 8].contains(tabWidth) ? tabWidth : 4, showsChanges: showsChanges)
    }

    let typeNBashScrollPolicy = OverscrollPolicy(
        percent: 0.5,
        maxPoints: 40,
        minPoints: 20,
        activationStartFraction: 0.15,
        activationRangeFraction: 0.85
        )

    let typeNBashMDTheme = MarkdownEditorTheme(
        bodyText: NSColor(Color.foreground),
        mutedText: NSColor(Color.secondary),
        link: NSColor(Color.accentColor),
        incompleteLink: NSColor(Color.red.opacity(0.5)),
        findMatchHighlight: NSColor(Color.accentColor.opacity(0.32)),
        findCurrentMatchHighlight: NSColor(Color.accentColor),
        highlightColor: NSColor.systemYellow.withAlphaComponent(0.32)
        )

    let typeNBashInsetMDInsets = TextInsets(horizontal: 18, vertical: 12)


    @ViewBuilder private var previewContent: some View {
        switch model.preview {
            case .text(let contents):
                CodeEditorTextView(
                    text: Binding(
                        get: { contents },
                        set: { model.updatePreviewText($0) }
                    ),
                    fileURL: model.selectedFile, options: options, session: session,
                    savedText: model.editorGitBaseline ?? model.savedPreviewText,
                    comparesWithGit: model.comparesEditorWithGit,
                    bibliography: bibliography, sourceNavigationID: session.sourceNavigation?.id)
                // Each file gets a fresh editor, grammar, and undo stack.
                .id(model.selectedFile)

            case .table(let table):
                CSVPreviewView(table: table, session: session, onEdit: model.updatePreviewTable)
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
                    SwiftUI.Text("Select a file to preview")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))
                .background(Color.card)
            case .document(let data):
                DocumentPreviewView(data: data)
                    .id(model.selectedFile)
            case .word(let document):
                WordPreviewView(document: document)
                    .id(document.url)
            case .image(let data):
                ImagePreviewView(data: data)
                    .id(model.selectedFile)
            case .markdown(let text) where mdViewSelection == .plain:
                CodeEditorTextView(
                    text: Binding(
                        get: { text },
                        set: { model.updatePreviewText($0) }
                    ),
                    fileURL: model.selectedFile, options: options, session: session,
                    savedText: model.editorGitBaseline ?? model.savedPreviewText,
                    comparesWithGit: model.comparesEditorWithGit,
                    bibliography: bibliography, sourceNavigationID: session.sourceNavigation?.id)
                // Keyed on the style too, so toggling swaps surfaces cleanly.
                .id([model.selectedFile?.absoluteString, "plain"])
            case .markdown(let text):
                    NativeTextViewWrapper(
                        text: Binding(
                            get: { text },
                            set: { model.updatePreviewText($0) }
                        ),
                        configuration: .init(
                            theme: typeNBashMDTheme,
                            textInsets: typeNBashInsetMDInsets,
                            heightBehavior: .scrolls
                        )
                    )
                    .id(model.selectedFile)
        }
    }
}
