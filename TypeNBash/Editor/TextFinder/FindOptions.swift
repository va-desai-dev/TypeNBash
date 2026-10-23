import Foundation
import Defaults
import TextFind

/// Matching semantics shared by document and project search; no UI or query state.
nonisolated struct FindOptions: Equatable, Sendable {
    var regularExpression = false
    var ignoresCase = false
    var wholeWord = false
    var literal = false
    var ignoresDiacritics = false
    var ignoresWidth = false
    var dotMatchesNewlines = false
    var anchorsMatchLines = true
    var unicodeBoundaries = false
    var unescapesReplacement = true

    @MainActor init(defaults: UserDefaults = .standard) {
        AppDefaults.register(in: defaults)
        regularExpression = defaults[.findUsesRegularExpression]
        ignoresCase = defaults[.findIgnoresCase]
        wholeWord = defaults[.findMatchesFullWord]
        literal = defaults[.findTextIsLiteralSearch]
        ignoresDiacritics = defaults[.findTextIgnoresDiacriticMarks]
        ignoresWidth = defaults[.findTextIgnoresWidth]
        dotMatchesNewlines = defaults[.findRegexIsSingleline]
        anchorsMatchLines = defaults[.findRegexIsMultiline]
        unicodeBoundaries = defaults[.findRegexUsesUnicodeBoundaries]
        unescapesReplacement = defaults[.findRegexUnescapesReplacementString]
    }

    var mode: TextFind.Mode {
        if regularExpression {
            return .regularExpression(options: NSRegularExpression.Options()
                .union(ignoresCase ? .caseInsensitive : [])
                .union(dotMatchesNewlines ? .dotMatchesLineSeparators : [])
                .union(anchorsMatchLines ? .anchorsMatchLines : [])
                .union(unicodeBoundaries ? .useUnicodeWordBoundaries : []),
                unescapesReplacement: unescapesReplacement)
        }
        return .textual(options: String.CompareOptions()
            .union(ignoresCase ? .caseInsensitive : [])
            .union(literal ? .literal : [])
            .union(ignoresDiacritics ? .diacriticInsensitive : [])
            .union(ignoresWidth ? .widthInsensitive : []), fullWord: wholeWord)
    }
}
