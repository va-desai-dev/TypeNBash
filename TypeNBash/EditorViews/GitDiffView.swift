import SwiftUI

struct GitDiffView: View {
    var onClose: (() -> Void)?
    @State private var model: GitDiffModel
    @State private var scrollRow: Int?

    init(directory: URL, selectedFile: URL?) {
        _model = State(initialValue: GitDiffModel(directory: directory, selectedFile: selectedFile))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if model.isLoading {
                ProgressView("Loading changes…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = model.errorMessage {
                ContentUnavailableView("Comparison unavailable", systemImage: "exclamationmark.triangle",
                                       description: Text(error))
            } else if let result = model.result, !result.rows.isEmpty {
                let file = result.files.first { $0.path == result.selectedPath }
                GitDiffPane(title: "\(model.scope.leftTitle) → \(model.scope.rightTitle)",
                            rows: result.rows, deleted: file?.status == "Deleted", scrollRow: $scrollRow)
                if let message = result.message {
                    Text(message).font(.caption).foregroundStyle(.secondary).padding(8)
                }
            } else {
                ContentUnavailableView("Changes", systemImage: "arrow.left.arrow.right",
                                       description: Text(model.result?.message ?? "Select a changed file."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .safeAreaBar(edge: .top) {
            VStack(spacing: 0) {
                HStack {
                    Label("Changes", systemImage: "arrow.left.arrow.right").font(.headline)
                    Picker("Compare", selection: $model.scope) {
                        ForEach(GitDiffScope.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    Spacer()
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refresh() } }
                        .disabled(model.isLoading)
                    if let onClose {
                        Button("Close", systemImage: "xmark", action: onClose).labelStyle(.iconOnly)
                    }
                }
                .padding(14)
                Divider()
            }
        }
        .safeAreaBar(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                HStack {
                    Text(model.selectedPath ?? "Saved files only — save editor changes before comparing.")
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("Read-only · − Removed / + Added · 3 context lines")
                }
                .font(.caption).foregroundStyle(.secondary)
                .padding(10)
            }
        }
        .background(Color.card)
        .task { await model.refresh() }
        .onChange(of: model.scope) { _, _ in
            scrollRow = nil
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedPath) { _, _ in scrollRow = nil }
    }
}

struct GitDiffFileList: View {
    @State private var model: GitDiffModel

    var body: some View {
        List(selection: Binding(get: { model.selectedPath }, set: model.select)) {
            ForEach(model.result?.files ?? []) { file in
                VStack(alignment: .leading, spacing: 3) {
                    Text(file.path).lineLimit(2).truncationMode(.middle)
                        .strikethrough(file.status == "Deleted")
                    Text(file.status).font(.caption)
                        .foregroundStyle(file.status == "Deleted" ? Color.red : Color.secondary)
                    if file.oldPath != file.path {
                        Text("From \(file.oldPath)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .tag(file.path)
            }
        }
    }
}

struct GitDiffPane: View {
    let title: String
    let rows: [GitDiffRow]
    let deleted: Bool
    @Binding var scrollRow: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                if deleted {
                    Label("Deleted file — previous contents shown below", systemImage: "doc.badge.minus")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .padding(10)
            Divider()
            GeometryReader { geometry in
                ScrollView([.horizontal, .vertical]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            let removed = row.left?.changed == true
                            let added = row.right?.changed == true
                            let line = row.right ?? row.left
                            HStack(spacing: 8) {
                                Text(row.left?.number.map(String.init) ?? "")
                                    .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                                Text(row.right?.number.map(String.init) ?? "")
                                    .foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                                Text(removed ? "−" : added ? "+" : " ")
                                    .frame(width: 10)
                                Text(line?.text ?? " ")
                                    .textSelection(.enabled)
                            }
                            .frame(maxWidth: .infinity)
                            .font(.system(size: 12, design: .monospaced))
                            .background(row.isHeader ? Color.secondary.opacity(0.12)
                                        : removed || added ? (removed ? Color.red : Color.green).opacity(0.14)
                                        : Color.clear)
                            .id(row.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollPosition(id: $scrollRow, anchor: .top)
            }
        }
    }
}
