import SwiftUI

/// The comparison canvas: the scope picker above, the changed-file list beside
/// the diff, and the status line below.
///
/// The chrome is stacked rather than hung off `safeAreaInset`, which is how
/// `FileViewer` does it. A safe area only reaches views SwiftUI lays out
/// itself, and neither pane here is one: `HSplitView` is `NSSplitView`
/// underneath and hosts each side as its own root, and `GitDiffTextPane` is an
/// `NSScrollView`. So neither the list nor the diff was inset — both ran their
/// full height under the bars and the window toolbar, hiding their first and
/// last rows.
///
/// Stacking is what failed the first time round, because the pane sized itself
/// to its document and grew past the window. That is fixed where it belongs,
/// in `GitDiffTextPane.sizeThatFits(_:nsView:context:)`.
struct GitDiffView: View {
    /// Passed in rather than owned: `GitDiffFileList` is a sibling in the
    /// sidebar, not a child, so the session lives in `CanvasView` — the nearest
    /// common ancestor — and refreshing is driven from there too. Holding it as
    /// private `@State` here left the list with no way to reach it.
    let model: GitDiffModel
    var onClose: (() -> Void)?
    var showsFooter = true

    var body: some View {
        comparison
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .safeAreaBar(edge: .top) {
                PaneBar {
                    Spacer()
                    GitDiffRefreshButton(model: model)
                }
            }
            .safeAreaBar(edge: .bottom) {
                if showsFooter {
                    PaneBar(edge: .bottom) {
                        GitDiffStatusLabel(model: model)
                        Spacer()
                        Text("Read-only · − Removed / + Added")
                    }
                }
            }
    }

    /// The file the comparison is currently showing, for the deleted badge.
    private var file: GitDiffFile? {
        guard let result = model.result else { return nil }
        return result.files.first { $0.path == result.selectedPath }
    }

    @ViewBuilder private var comparison: some View {
        if model.isLoading {
            ProgressView("Loading changes…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error = model.errorMessage {
            ContentUnavailableView("Comparison unavailable", systemImage: "exclamationmark.triangle",
                                   description: Text(error))
        } else if let result = model.result, !result.rows.isEmpty {
            let contentKey = "\(model.scope.rawValue)|\(result.selectedPath ?? "")|\(result.rows.count)"
            GitDiffTextPane(
                rows: result.rows,
                fileURL: result.selectedPath.map { model.directory.appending(path: $0) },
                contentKey: contentKey
            )
            .backgroundStyle(Color.card)
            // A new comparison gets a new text view, the way each file gets a
            // new editor. Refilling one in place is what loses the theme's text
            // color — see `GitDiffTextPane.makeNSView(context:)`.
            .id(contentKey)
        } else {
            ContentUnavailableView("Changes", systemImage: "arrow.left.arrow.right",
                                   description: Text(model.result?.message ?? "Select a changed file."))
            .frame(alignment: .center)
        }
    }

}

struct GitDiffRefreshButton: View {
    let model: GitDiffModel

    var body: some View {
        Button("Refresh", systemImage: "arrow.clockwise") {
            Task { await model.refresh() }
        }
        .labelStyle(.titleOnly)
        .disabled(model.isLoading)
    }
}

/// The file being compared, and the comparison's own note about it.
struct GitDiffStatusLabel: View {
    let model: GitDiffModel

    var body: some View {
        Text(model.selectedPath ?? "Saved files only — save editor changes before comparing.")
            .lineLimit(1).truncationMode(.middle)
        if let message = model.result?.message, model.result?.rows.isEmpty == false {
            Text("\(message)").lineLimit(1)
        }
    }
}

/// Insertions and deletions across the whole comparison.
struct GitDiffStatsLabel: View {
    let model: GitDiffModel

    var body: some View {
        let stats = model.result?.stats ?? GitDiffStats()
        Text("+ \(stats.insertions, format: .number)")
            .foregroundStyle(Color.green)
            .lineLimit(1)
        Text("- \(stats.deletions, format: .number)")
            .foregroundStyle(Color.red)
            .lineLimit(1)
    }
}

struct GitDiffScopePicker: View {
    let model: GitDiffModel

    var body: some View {
        Picker("Compare", selection: Binding(get: { model.scope }, set: model.setScope)) {
            ForEach(GitDiffScope.allCases) {
                Text($0.rawValue)
                    .font(.body)
                    .tag($0)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
    }
}

struct GitDiffFileList: View {
    /// The list shares the comparison's model rather than owning one, so
    /// selecting a row is the same `select(_:)` that reloads the diff.
    let model: GitDiffModel
    @State private var highlightedFile: String?

    var body: some View {
        mainList
            .safeAreaInset(edge: .top) {
                PaneBar {
                    Text("CHANGES:")
                    Spacer()
                    GitDiffScopePicker(model: model)
                }
            }
            .safeAreaInset(edge: .bottom) {
                PaneBar(edge: .bottom) {
                    Image(systemName: "arrow.up.arrow.down")
                        .foregroundStyle(Color(NSColor.controlAccentColor))
                    Spacer()
                    GitDiffStatsLabel(model: model)
                }
            }
    }

    @ViewBuilder func badgeView(for value: String, accent: Color) -> some View {
        ZStack {
            Text(value)
                .font(.caption.monospaced().weight(.heavy))
        }
        .frame(width: 16, height: 16)
        .contentShape(Rectangle())
        .background(accent.opacity(0.7),
                    in: .rect(cornerRadius: 3, style: .continuous))
    }

    var mainList: some View {
        List(selection: $highlightedFile) {
            ForEach(model.result?.files ?? []) { file in
                HStack(spacing: 8) {
                    FileTypeIconView(icon: file.icon, symbolStyle: Color.accentColor)
                    Text(file.label)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(file.status == .deleted)
                    Spacer()
                    badgeView(for: file.status.letter, accent: file.status.color)
                    if file.oldPath != file.path {
                        Text("From \(file.oldPath)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .tag(file.id)
                .onTapGesture(count: 1) {
                    // Highlight locally at once, like `FileBrowserList`, then
                    // load the diff; `onChange(of: model.selectedPath)` below
                    // keeps the highlight in sync if the model picks another file.
                    highlightedFile = file.id
                    model.select(file.path)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
        .onChange(of: model.selectedPath, initial: true) { _, value in
            highlightedFile = value
        }
    }
}


