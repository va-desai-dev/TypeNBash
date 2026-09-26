//
//  AppDefaults.swift
//  TypeNBash
//

import Foundation
import Defaults

/// The factory values for every user setting backed by a `DefaultKey`.
///
/// The typed `@AppStorage(.key)` initializers read their default from the
/// registration domain and force-cast it, so these must be registered before
/// any view that uses them is created — `TypeNBashApp.init` does that.
enum AppDefaults {

    static func register(in defaults: UserDefaults = .standard) {
        defaults.register(defaults: [
            // Editor
            DefaultKeys.editorShowsInvisibles.rawValue: true,
            DefaultKeys.editorShowsIndentGuides.rawValue: true,
            DefaultKeys.editorShowsLineNumbers.rawValue: true,
            DefaultKeys.editorShowsChanges.rawValue: true,
            DefaultKeys.editorWrapsLines.rawValue: true,
            DefaultKeys.editorAutomaticCompletion.rawValue: true,
            DefaultKeys.editorUsesSpaces.rawValue: true,
            DefaultKeys.editorTabWidth.rawValue: 4,

            // Find
            DefaultKeys.findUsesRegularExpression.rawValue: false,
            DefaultKeys.findIgnoresCase.rawValue: false,
            DefaultKeys.findInSelection.rawValue: false,
            DefaultKeys.findIsWrap.rawValue: true,
            DefaultKeys.findMatchesFullWord.rawValue: false,
            DefaultKeys.findSearchesIncrementally.rawValue: true,
            DefaultKeys.findTextIsLiteralSearch.rawValue: false,
            DefaultKeys.findTextIgnoresDiacriticMarks.rawValue: false,
            DefaultKeys.findTextIgnoresWidth.rawValue: false,
            DefaultKeys.findRegexIsSingleline.rawValue: false,
            DefaultKeys.findRegexIsMultiline.rawValue: true,
            DefaultKeys.findRegexUsesUnicodeBoundaries.rawValue: false,
            DefaultKeys.findRegexUnescapesReplacementString.rawValue: true,
            DefaultKeys.findResultViewFontSize.rawValue: 13.0,
            DefaultKeys.findHistory.rawValue: [String](),
            DefaultKeys.replaceHistory.rawValue: [String](),

            // Find panel invisibles
            DefaultKeys.showInvisibles.rawValue: true,
            DefaultKeys.showInvisibleNewLine.rawValue: true,
            DefaultKeys.showInvisibleTab.rawValue: true,
            DefaultKeys.showInvisibleSpace.rawValue: true,
            DefaultKeys.showInvisibleWhitespaces.rawValue: true,
            DefaultKeys.showInvisibleControl.rawValue: true,
        ])
    }
}
