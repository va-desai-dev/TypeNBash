//
//  DefaultKeys.swift
//
//  CotEditor
//  https://coteditor.com
//
//  Created by 1024jp on 2017-02-14.
//
//  ---------------------------------------------------------------------------
//
//  © 2016-2026 1024jp
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//  https://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation
import Defaults
import StringUtils
import AppKit

extension DefaultKeys {

    // Typographic Defaults for Editor
    static let font = DefaultKey<Data?>("font")
    static let shouldAntialias = DefaultKey<Bool>("shouldAntialias")
    static let ligature = DefaultKey<Bool>("ligature")
    static let monospacedFont = DefaultKey<Data?>("monospacedFont")
    static let monospacedShouldAntialias = DefaultKey<Bool>("monospacedShouldAntialias")
    static let monospacedLigature = DefaultKey<Bool>("monospacedLigature")

    // Showing Invisibles
    static let showInvisibles = DefaultKey<Bool>("showInvisibles")
    static let showInvisibleNewLine = DefaultKey<Bool>("showInvisibleNewLine")
    static let showInvisibleTab = DefaultKey<Bool>("showInvisibleTab")
    static let showInvisibleSpace = DefaultKey<Bool>("showInvisibleSpace")
    static let showInvisibleWhitespaces = DefaultKey<Bool>("showInvisibleWhitespaces")
    static let showInvisibleControl = DefaultKey<Bool>("showOtherInvisibleChars")

    // Find & Search for Tokens
    static let findHistory = DefaultKey<[String]>("findHistory")
    static let replaceHistory = DefaultKey<[String]>("replaceHistory")
    static let findUsesRegularExpression = DefaultKey<Bool>("findUsesRegularExpression")
    static let findIgnoresCase = DefaultKey<Bool>("findIgnoresCase")
    static let findInSelection = DefaultKey<Bool>("findInSelection")
    static let findIsWrap = DefaultKey<Bool>("findIsWrap")
    static let findMatchesFullWord = DefaultKey<Bool>("findMatchesFullWord")
    static let findSearchesIncrementally = DefaultKey<Bool>("findSearchesIncrementally")
    static let findTextIsLiteralSearch = DefaultKey<Bool>("findTextIsLiteralSearch")
    static let findTextIgnoresDiacriticMarks = DefaultKey<Bool>("findTextIgnoresDiacriticMarks")
    static let findTextIgnoresWidth = DefaultKey<Bool>("findTextIgnoresWidth")
    static let findRegexIsSingleline = DefaultKey<Bool>("findRegexIsSingleline")
    static let findRegexIsMultiline = DefaultKey<Bool>("findRegexIsMultiline")
    static let findRegexUsesUnicodeBoundaries = DefaultKey<Bool>("regexUsesUnicodeBoundaries")
    static let findRegexUnescapesReplacementString = DefaultKey<Bool>("regexUnescapesReplacementString")

    // TypeNBash theme overrides, stored as sRGB `#RRGGBBAA` codes.
    // Unset (nil) means the slot uses the built-in TypeNBash theme color.
    static let textColor = DefaultKey<String?>("editor.textView.theme.text")
    static let backgroundColor = DefaultKey<String?>("editor.textView.theme.background")
    static let invisiblesColor = DefaultKey<String?>("editor.textView.theme.invisibles")
    static let lineHighlight = DefaultKey<String?>("editor.textView.theme.lineHighlight")
    static let insertionPoint = DefaultKey<String?>("editor.textView.theme.insertionPoint")
    static let selectionColor = DefaultKey<String?>("editor.textView.theme.selection")

    static let keywords = DefaultKey<String?>("editor.textView.theme.keywords")
    static let commands = DefaultKey<String?>("editor.textView.theme.commands")
    static let declaredtypes = DefaultKey<String?>("editor.textView.theme.types")
    static let variables = DefaultKey<String?>("editor.textView.theme.variables")
    static let values = DefaultKey<String?>("editor.textView.theme.values")
    static let numbers = DefaultKey<String?>("editor.textView.theme.numbers")
    static let strings = DefaultKey<String?>("editor.textView.theme.strings")
    static let characters = DefaultKey<String?>("editor.textView.theme.characters")
    static let comments = DefaultKey<String?>("editor.textView.theme.comments")
    static let attributes = DefaultKey<String?>("editor.textView.theme.attributes")

    // App chrome colors; `textColor` and `backgroundColor` double as the
    // chrome's foreground and card colors.
    static let accentColor = DefaultKey<String?>("app.theme.accent")
    static let secondaryColor = DefaultKey<String?>("app.theme.secondary")
    // Diff pane colors: the gutter marker, and the wash behind changed rows.
    static let diffAddedColor = DefaultKey<String?>("app.theme.diffAdded")
    static let diffRemovedColor = DefaultKey<String?>("app.theme.diffRemoved")
    /// Paints the whole window with a card-to-foreground gradient instead of the flat card.
    static let gradientBackground = DefaultKey<Bool>("app.theme.gradientBackground")



    // TypeNBash editor options, shared by every editor pane and the Settings window
    static let editorShowsInvisibles = DefaultKey<Bool>("editor.showsInvisibles")
    static let editorShowsIndentGuides = DefaultKey<Bool>("editor.showsIndentGuides")
    static let editorShowsLineNumbers = DefaultKey<Bool>("editor.showsLineNumbers")
    static let editorShowsChanges = DefaultKey<Bool>("editor.showsChanges")
    static let editorWrapsLines = DefaultKey<Bool>("editor.wrapsLines")
    static let editorAutomaticCompletion = DefaultKey<Bool>("editor.automaticCompletion")
    static let editorUsesSpaces = DefaultKey<Bool>("editor.usesSpaces")
    static let editorTabWidth = DefaultKey<Int>("editor.tabWidth")
    static let findResultViewFontSize = DefaultKey<Double>("findResultViewFontSize")


    // TypeNBash file browser, shared by every window
    static let fileBrowserLayout = DefaultKey<FileTreeLayout>("fileBrowser.layout")
    static let fileBrowserSortKey = DefaultKey<FileTreeSortKey>("fileBrowser.sortKey")
    static let fileBrowserSortsAscending = DefaultKey<Bool>("fileBrowser.sortsAscending")
    static let fileBrowserFoldersFirst = DefaultKey<Bool>("fileBrowser.foldersFirst")
}
