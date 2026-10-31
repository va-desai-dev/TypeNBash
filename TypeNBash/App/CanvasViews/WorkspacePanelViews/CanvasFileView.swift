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


struct FileViewer: View {
    @Bindable var model: FileBrowserModel
    /// Owned by the enclosing SwiftUI view and shared with the header and
    /// footer, which drive and read this editor's text view.
    let session: EditorSession
    /// Whether `.md` files render formatted or open in the code editor.
    var mdViewSelection: MDViewStyle = .fancy
    var bibliography: BibLibrary? = nil
    @State private var editorIsFocused = true

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
            case .failed(let error):
                ContentUnavailableView {
                    Text(error).foregroundColor(.red)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))

            case .none:
                ContentUnavailableView {
                    SwiftUI.Text("Select a file to preview")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .init(horizontal: .center, vertical: .center))
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
                .id([model.selectedFile?.absoluteString, "plain"])
            case .markdown(let text):
                RichMarkdownEditor(
                    mdText: Binding(
                        get: { text },
                        set: { model.updatePreviewText($0) }
                    ),
                    editorIsFocused: $editorIsFocused,
                    session: session,
                    fileURL: model.selectedFile
                )
                .id(model.selectedFile)
        }
    }
}
import MarkdownEngine
import MarkdownEngineLatex


// MARK: MARKDOWN ENGINE RENDERER TEST

/// swift-markdown-engine's editor. Formatted now shows `RichMarkdownEditor`; this
/// stays for comparison.
struct MarkdownEditor: View {
    @Binding var mdText: String

    @Binding var editorIsFocused: Bool
    let session: EditorSession
    @State private var finder = MarkdownFindController()
    /// The project's .bib, for green/red citation keys; nil turns the colors off.
    var bibliography: BibLibrary? = nil
    @Environment(\.colorScheme) private var colorScheme

    /// Built once: the engine only reads its services when the view is made,
    /// and a bridge built per body pass would be thrown away on every keystroke.
    private static let latex = SwiftMathBridge()

    private var configuration: MarkdownEditorConfiguration {
        var config = MarkdownEditorConfiguration.default

        config.services.syntaxHighlighter = MarkdownEngineCodeHighlighter.shared
        config.services.latex = Self.latex

        config.extensions = [HighlightExtension(), StrikethroughExtension()]
        config.directives = [FontDirective(), ColorDirective()]
        config.scrollers.hasHorizontalScroller = false
        config.spellChecking = SpellCheckingPolicy(
            continuousSpellChecking: false,
            grammarChecking: false,
            automaticSpellingCorrection: false,
            automaticQuoteSubstitution: false
        )
        config.paragraph = ParagraphStyle(spacingFactor: 1.15)
        config.theme = AppTheme.shared.markdownTheme
        config.overscroll.maxPoints = 100
        config.textInsets = TextInsets(horizontal: 60, vertical: 12)
        // Typed syntax settles into rich text, as in Notes or Ulysses.
        config.revealsFormattingAtCaret = false
        return config
    }
    var body: some View {
        NativeTextViewWrapper(
            text: $mdText,
            configuration: configuration,
            fontSize: 14,
            isFocused: $editorIsFocused
        )
        .background(MarkdownFindBridge(finder: finder, session: session))
        // The engine doesn't follow the caret at full width; see the follower.
        .background(MarkdownEngineCaretFollower())
        // Matched and unmatched citation keys, as in the code editor.
        .background(MarkdownEngineCitationHighlighter(library: bibliography))
        // Code blocks take the code editor's colors, which the engine's own
        // theme doesn't carry; restyle when they change.
        .onChange(of: AppTheme.shared.editorTheme(colorScheme)) {
            MarkdownEngineCodeHighlighter.shared.paletteDidChange()
        }
    }
}

extension AppTheme {
    /// The engine's text colors. The Markdown editor sits straight on the
    /// pane, so it takes the chrome's foreground rather than the code
    /// editor's, which assumes its own background in light mode.
    var markdownTheme: MarkdownEditorTheme {
        MarkdownEditorTheme(
            bodyText: NSColor(foreground),
            mutedText: NSColor(secondary),
            link: NSColor(accent),
            incompleteLink: NSColor(Color.red.opacity(0.5)),
            findMatchHighlight: NSColor.unemphasizedSelectedTextBackgroundColor,
            findCurrentMatchHighlight: NSColor.textHighlighterColor,
            latexLightModeText: NSColor(foreground),
            latexDarkModeText: NSColor(foreground),
            highlightColor: NSColor.systemYellow.withAlphaComponent(0.32)
        )
    }
}
