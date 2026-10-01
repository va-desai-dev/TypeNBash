import SwiftUI

/// The app's own folder browser, shared by every "choose a location" flow so
/// local and SSH workspaces browse the same way. It owns no file system: the
/// caller lists `entries` for `directory` and reacts to `onBrowse`.
///
/// Folder rows navigate. File rows, when the caller lists any, select through
/// `onSelectFile`, and the selected one is highlighted.
struct WorkspaceBrowserSheet<Accessory: View>: View {
    let title: String
    let directory: URL?
    let entries: [WorkspaceFileEntry]
    let isBusy: Bool
    let error: String?
    @Binding var showsHiddenFiles: Bool
    /// Shown in the path field until the first listing arrives.
    var pendingPath = ""
    var emptyText = "No subfolders"
    var selectedFile: URL?
    var onSelectFile: ((URL) -> Void)?
    /// Called with the path to list, or nil for the home folder.
    let onBrowse: (String?) -> Void
    let onCancel: () -> Void
    let confirmTitle: String
    let canConfirm: Bool
    let onConfirm: () -> Void
    /// Extra controls between the list and the buttons.
    @ViewBuilder var accessory: Accessory

    @State private var browsePath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            HStack {
                Button("Home", systemImage: "house") { onBrowse(nil) }
                Button("Up", systemImage: "arrow.up") {
                    if let directory {
                        onBrowse(directory.deletingLastPathComponent().path)
                    }
                }
                .disabled(directory == nil || directory?.path == "/")
                Spacer()
                Toggle("Hidden folders", isOn: $showsHiddenFiles)
                    .onChange(of: showsHiddenFiles) {
                        onBrowse(directory?.path)
                    }
            }
            .disabled(isBusy)
            HStack {
                TextField("Folder path, such as ~/projects", text: $browsePath)
                    .onSubmit { onBrowse(browsePath) }
                Button("Go") { onBrowse(browsePath) }
            }
            .disabled(isBusy)
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            List(entries) { entry in
                Button {
                    if entry.isDirectory {
                        onBrowse(entry.url.path)
                    } else {
                        onSelectFile?(entry.url)
                    }
                } label: {
                    Label {
                        Text(entry.url.lastPathComponent).foregroundStyle(Color.foreground)
                    } icon: {
                        Image(systemName: entry.isDirectory ? "folder.fill" : "books.vertical")
                            .tint(Color.accentColor)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .listRowSeparator(.hidden)
                .listRowBackground(
                    entry.url == selectedFile ? Color.accentColor.opacity(0.25) : Color.clear
                )
            }
            .scrollContentBackground(.hidden)
            .disabled(isBusy)
            .overlay {
                if isBusy {
                    ProgressView()
                } else if entries.isEmpty, error == nil {
                    Text(emptyText).foregroundStyle(.secondary)
                }
            }
            accessory
            HStack {
                Button("Cancel", role: .cancel, action: onCancel)
                Spacer()
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canConfirm)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .background(Color.card)
        .interactiveDismissDisabled(isBusy)
        .onAppear { browsePath = directory?.path(percentEncoded: false) ?? pendingPath }
        .onChange(of: directory) {
            browsePath = directory?.path(percentEncoded: false) ?? ""
        }
    }
}

extension WorkspaceBrowserSheet where Accessory == EmptyView {
    init(title: String, directory: URL?, entries: [WorkspaceFileEntry],
         isBusy: Bool, error: String?, showsHiddenFiles: Binding<Bool>,
         pendingPath: String = "", onBrowse: @escaping (String?) -> Void,
         onCancel: @escaping () -> Void, confirmTitle: String,
         canConfirm: Bool, onConfirm: @escaping () -> Void) {
        self.init(title: title, directory: directory, entries: entries,
                  isBusy: isBusy, error: error, showsHiddenFiles: showsHiddenFiles,
                  pendingPath: pendingPath, onBrowse: onBrowse, onCancel: onCancel,
                  confirmTitle: confirmTitle, canConfirm: canConfirm,
                  onConfirm: onConfirm) { EmptyView() }
    }
}
