import SwiftUI

struct SourceControlView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: SourceControlModel

    init(directory: URL) {
        _model = State(initialValue: SourceControlModel(directory: directory))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Source Control", systemImage: "point.3.connected.trianglepath.dotted")
                    .font(.headline)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Refresh", systemImage: "arrow.clockwise") {
                    Task { await model.run(.refresh) }
                }
                .disabled(model.isBusy || model.account.isBusy)
            }
            GitHubAccountView(model: model.account)
                .disabled(model.isBusy)
            Divider()
            if let snapshot = model.snapshot {
                Text(snapshot.root.path(percentEncoded: false))
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                Label(snapshot.branch, systemImage: "arrow.triangle.branch")
                List(snapshot.changes) { change in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(change.path).lineLimit(1).truncationMode(.middle)
                            Text(change.conflicted ? "Conflict" : change.staged
                                 ? (change.unstaged ? "Staged · additional changes" : "Staged") : "Unstaged")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if change.unstaged && !change.conflicted {
                            Button("Stage") { Task { await model.run(.stage(change.path)) } }
                        }
                        if change.staged && !snapshot.unborn && !change.conflicted {
                            Button("Unstage") { Task { await model.run(.unstage(change.path)) } }
                        }
                    }
                }
                .overlay {
                    if snapshot.changes.isEmpty { Text("Working tree is clean").foregroundStyle(.secondary) }
                }
                .disabled(model.isBusy || model.account.isBusy)
                TextField("Commit message", text: $model.commitMessage, axis: .vertical)
                    .lineLimit(2...4)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.isBusy || model.account.isBusy)
                HStack {
                    Button("Commit Staged Changes") {
                        Task { await model.run(.commit(model.commitMessage)) }
                    }
                    .disabled(!model.canCommit)
                    Spacer()
                    if !snapshot.remotes.isEmpty {
                        Picker("Remote", selection: $model.selectedRemote) {
                            ForEach(snapshot.remotes, id: \.self) { Text($0).tag($0) }
                        }
                        .fixedSize()
                        Button("Fetch") { Task { await model.run(.fetch(model.selectedRemote)) } }
                        Button("Push", systemImage: "arrow.up") {
                            Task { await model.run(.push(model.selectedRemote)) }
                        }
                        .disabled(snapshot.unborn || snapshot.detached)
                        .help("Push \(snapshot.branch) to \(model.selectedRemote)/\(snapshot.branch)")
                    }
                }
                .disabled(model.isBusy || model.account.isBusy)
                Text("Commit saves locally. Push publishes the current branch under the same name on the selected remote.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Spacer()
            }
            if let error = model.errorMessage {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            if let result = model.resultMessage {
                Text(result).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(model.isBusy || model.account.isBusy)
            }
        }
        .padding(20)
        .frame(width: 620, height: 610)
        .background(Color.card)
        .interactiveDismissDisabled(model.isBusy || model.account.isBusy)
        .task { await model.run(.refresh) }
    }
}
