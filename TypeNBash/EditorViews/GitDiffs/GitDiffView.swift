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

    var body: some View {
        VStack(spacing: 0) {
            header
            comparison
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(Color.card)
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
            HSplitView {
                GitDiffFileList(model: model)
                    .frame(minWidth: 250, maxWidth: 300)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .backgroundStyle(Color.card)
                let contentKey = "\(model.scope.rawValue)|\(result.selectedPath ?? "")|\(result.rows.count)"
                GitDiffTextPane(
                    rows: result.rows,
                    fileURL: result.selectedPath.map { model.directory.appending(path: $0) },
                    contentKey: contentKey
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .backgroundStyle(Color.card)
                // A new comparison gets a new text view, the way each file gets a
                // new editor. Refilling one in place is what loses the theme's text
                // color — see `GitDiffTextPane.makeNSView(context:)`.
                .id(contentKey)
            }
        } else {
            ContentUnavailableView("Changes", systemImage: "arrow.left.arrow.right",
                                   description: Text(model.result?.message ?? "Select a changed file."))
            .frame(alignment: .center)
        }
    }

    private var header: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center) {
                Picker("Compare", selection: Binding(get: { model.scope }, set: model.setScope)) {
                    ForEach(GitDiffScope.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
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

    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack {
                Text(model.selectedPath ?? "Saved files only — save editor changes before comparing.")
                    .lineLimit(1).truncationMode(.middle)
                // Only alongside a comparison: with no rows to show, the same
                // message is already the placeholder's description.
                if let message = model.result?.message, model.result?.rows.isEmpty == false {
                    Text("· \(message)").lineLimit(1)
                }
                Spacer()
                Text("Read-only · − Removed / + Added")
            }
            .foregroundStyle(Color.foreground)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
        }
        .background(Color.card)
    }
}

struct GitDiffFileList: View {
    /// The list shares the comparison's model rather than owning one, so
    /// selecting a row is the same `select(_:)` that reloads the diff.
    let model: GitDiffModel

    var body: some View {
        List(selection: Binding(get: { model.selectedPath }, set: model.select)) {
            ForEach(model.result?.files ?? []) { file in
                HStack(spacing: 8) {
                    Image(systemName: file.icon)
                        .frame(width: 16)
                    Text(file.path)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .strikethrough(file.status == "Deleted")
                    Spacer()
                    Text(file.status.prefix(1))
                        .font(.caption)
                        .backgroundStyle(Color.accentColor)
                        .clipShape(.rect.inset(by: 6))
                    if file.oldPath != file.path {
                        Text("From \(file.oldPath)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 24)
                .contentShape(Rectangle())
                .tag(file.path)
            }
        }
        .scrollContentBackground(.hidden)
        .listStyle(.sidebar)
    }
}
