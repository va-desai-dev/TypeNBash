import SwiftUI

struct ProjectSearchControls: View {
    @Bindable var model: ProjectSearchModel
    @State private var showsFilters = false
    @State private var findFocus = 0
    @State private var replaceFocus = 0


    private func dismiss() { model.showsSearch = false }


    var body: some View {
        VStack(spacing: 0) {
            // Same shape as the editor: a header row, then the find rows as its accessory,
            // so the header divider and the fields line up across the split.
            PaneBar(spacing: 2) {
                ProjectFindModeMenu(
                    findString: $model.query,
                    showsReplace: $model.showsReplacement
                ) { replacing in
                    if replacing { replaceFocus += 1 } else { findFocus += 1 }
                }
                ProjectSearchTypeMenu(
                    usesRegularExpression: $model.options.regularExpression)
                Spacer(minLength: 0)
                ProjectSearchOptionButton(
                    ignoresCase: $model.options.ignoresCase, dismiss: dismiss,
                    settings: { advancedOptions }
                )
            } accessory: {
                findRows
            }
            .disabled(model.isReplacing)
            if showsFilters {
                PaneBar {
                    VStack(alignment: .leading, spacing: 6) {
                        TextField("Include: *.swift, Sources/**", text: $model.includes)
                        TextField("Exclude: .git, build/**", text: $model.excludes)
                    }
                    .padding(.vertical, 6)
                }
                .textFieldStyle(.roundedBorder)
                .modifier(FindBarContent())
                .disabled(model.isReplacing)
                .help("Comma-separated paths; * matches a name, ** spans folders.")
            }
            if let message = model.message {
                PaneBar {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled).padding(.vertical, 6)
                }
            }
        }
    }

    private var findRows: some View {
        PaneBar {
            VStack(spacing: 4) {
                FindField(
                    text: $model.query,
                    isCompact: true,
                    placeholder: "Find",
                    identifier: "project.search.query",
                    focusRequest: model.focusRequest + findFocus,
                    onSubmit: { model.schedule() },
                    onDismiss: dismiss, label: {}, trailing: {})
                if model.showsReplacement {
                    FindField(text: $model.replacement, isCompact: true, placeholder: "Replace with", systemImage: "pencil",
                              identifier: "search.replacement", focusRequest: replaceFocus,
                              onSubmit: { model.previewReplacement() }, onDismiss: dismiss, label: { }, trailing: { })
                    .frame(height: FindBarContent.rowHeight)
                    .disabled(model.query.isEmpty)
                }
            }
            // One 24pt find row plus this padding is exactly `PaneBar.rowHeight`.
            .padding(.vertical, 5)
        }
        .modifier(FindBarContent())
        .onExitCommand(perform: dismiss)
    }

    private var advancedOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            FindTextualOptionsView(matchesFullWord: $model.options.wholeWord,
                isLiteralSearch: $model.options.literal, ignoresDiacriticMarks: $model.options.ignoresDiacritics,
                ignoresWidth: $model.options.ignoresWidth)
            FindRegularExpressionOptionsView(isSingleLine: $model.options.dotMatchesNewlines,
                isMultiline: $model.options.anchorsMatchLines, usesUnicodeBoundaries: $model.options.unicodeBoundaries,
                unescapesReplacementString: $model.options.unescapesReplacement)
        }.controlSize(.small)
    }
}
