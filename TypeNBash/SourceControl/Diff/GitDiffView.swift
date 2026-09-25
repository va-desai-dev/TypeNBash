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
                header
                    .background(Color.card)
            }
            .safeAreaBar(edge: .bottom) {
                if showsFooter {
                    GitDiffFooter(model: model)
                        .background(Color.card)
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

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Spacer()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.refresh() }
                }
                .labelStyle(.titleOnly)
                .disabled(model.isLoading)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()
        }
        .background(Color.card)
    }

}

struct GitDiffFooter: View {
    let model: GitDiffModel
    var showsSeparator = true

    var body: some View {
        VStack(spacing: 0) {
            if showsSeparator { Divider() }
            HStack(alignment: .center) {
                Text(model.selectedPath ?? "Saved files only — save editor changes before comparing.")
                    .lineLimit(1).truncationMode(.middle)
                if let message = model.result?.message, model.result?.rows.isEmpty == false {
                    Text("\(message)").lineLimit(1)
                }
                Spacer()
                Text("Read-only · − Removed / + Added")
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
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
                VStack(spacing: 0) {
                    header
                    Divider()
                }
                .background(Color.card)
            }
            .safeAreaInset(edge: .bottom, alignment: .leading) {
                VStack(alignment: .leading, spacing: 0) {
                    Divider()
                    HStack(alignment: .center) {
                        Image(systemName: "arrow.up.arrow.down")
                            .foregroundStyle(Color(NSColor.controlAccentColor))
                        Spacer()
                        let stats = model.result?.stats ?? GitDiffStats()
                        Text("+ \(stats.insertions, format: .number)")
                            .foregroundStyle(Color.green)
                            .lineLimit(1)
                        Text("- \(stats.deletions, format: .number)")
                            .foregroundStyle(Color.red)
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .background(Color.card)
            }
    }

    var header: some View {
        HStack(alignment: .center) {
            Text("CHANGES:")
            Spacer()
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
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
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
                    Image(systemName: file.icon)
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 16)
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


