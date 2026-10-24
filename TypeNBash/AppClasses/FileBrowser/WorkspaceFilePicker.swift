import SwiftUI

/// Lists one folder at a time of any `WorkspaceFileSystem` for picking a single
/// file: folders first, then the files `accepts` lets through. The same model
/// drives a local pick (keys, config files) and a remote one over SSH.
@MainActor
@Observable
final class WorkspaceFilePickerModel {
    var showsHiddenFiles: Bool
    var selectedFile: URL?
    private(set) var directory: URL?
    private(set) var entries: [WorkspaceFileEntry] = []
    private(set) var isBusy = false
    private(set) var error: String?

    let fileSystem: any WorkspaceFileSystem
    private let accepts: (URL) -> Bool
    private var task: Task<Void, Never>?
    private var generation = 0

    init(fileSystem: any WorkspaceFileSystem,
         showsHiddenFiles: Bool = false,
         accepts: @escaping (URL) -> Bool = { _ in true }) {
        self.fileSystem = fileSystem
        self.showsHiddenFiles = showsHiddenFiles
        self.accepts = accepts
    }

    /// Lists `path`, or the home folder when nil. Expands a leading `~`.
    func browse(path: String?) {
        let home = fileSystem.homeDirectory.path
        var target = path?.trimmingCharacters(in: .whitespacesAndNewlines) ?? home
        if target.isEmpty || target == "~" {
            target = home
        } else if target.hasPrefix("~/") {
            target = home + target.dropFirst(1)
        }
        let url = URL(fileURLWithPath: target).standardizedFileURL
        run { [self] in
            let listed = try await fileSystem.contentsOfDirectory(
                at: url, includingHiddenFiles: showsHiddenFiles)
            try Task.checkCancellation()
            directory = url
            entries = listed
                .filter { $0.isDirectory || accepts($0.url) }
                .sorted {
                    if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                    return $0.url.lastPathComponent
                        .localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
                }
            if let selectedFile, !entries.contains(where: { $0.url == selectedFile }) {
                self.selectedFile = nil
            }
        }
    }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        task?.cancel()
        generation &+= 1
        let request = generation
        error = nil
        isBusy = true
        task = Task {
            do { try await operation() }
            catch {
                if request == generation, !Task.isCancelled { self.error = error.localizedDescription }
            }
            if request == generation { isBusy = false }
        }
    }

    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
        isBusy = false
    }
}

/// The app's own "choose a file" sheet, used in place of `NSOpenPanel`.
/// Present it with `.sheet`; it dismisses itself after `onPick` or Cancel.
///
///     .sheet(isPresented: $choosingKey) {
///         WorkspaceFilePickerSheet(
///             title: "Choose SSH Key", fileSystem: LocalWorkspaceFileSystem(),
///             startPath: "~/.ssh", showsHiddenFiles: true, confirmTitle: "Use Key"
///         ) { identityPath = $0.path }
///     }
struct WorkspaceFilePickerSheet<Accessory: View>: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    /// Where to open, such as "~/.ssh". Nil, or a folder that can't be listed,
    /// falls back to the home folder.
    let startPath: String?
    var emptyText = "No folders or files"
    /// Shown on the confirm button; the selected file's name is appended.
    let confirmTitle: String
    let onPick: (URL) -> Void
    /// Extra controls between the list and the buttons; gets the model so it
    /// can act on the folder being shown.
    @ViewBuilder var accessory: (WorkspaceFilePickerModel) -> Accessory

    @State private var model: WorkspaceFilePickerModel
    @State private var triedStart = false

    init(title: String,
         fileSystem: any WorkspaceFileSystem,
         startPath: String? = nil,
         selectedFile: URL? = nil,
         showsHiddenFiles: Bool = false,
         emptyText: String = "No folders or files",
         accepts: @escaping (URL) -> Bool = { _ in true },
         confirmTitle: String = "Choose",
         onPick: @escaping (URL) -> Void,
         @ViewBuilder accessory: @escaping (WorkspaceFilePickerModel) -> Accessory) {
        self.title = title
        self.startPath = startPath
        self.emptyText = emptyText
        self.confirmTitle = confirmTitle
        self.onPick = onPick
        self.accessory = accessory
        let model = WorkspaceFilePickerModel(
            fileSystem: fileSystem, showsHiddenFiles: showsHiddenFiles, accepts: accepts)
        model.selectedFile = selectedFile
        _model = State(initialValue: model)
    }

    var body: some View {
        WorkspaceBrowserSheet(
            title: title,
            directory: model.directory,
            entries: model.entries,
            isBusy: model.isBusy,
            error: model.error,
            showsHiddenFiles: $model.showsHiddenFiles,
            pendingPath: startPath ?? "",
            emptyText: emptyText,
            selectedFile: model.selectedFile,
            onSelectFile: { model.selectedFile = $0 },
            onBrowse: { model.browse(path: $0) },
            onCancel: { model.cancel(); dismiss() },
            confirmTitle: model.selectedFile.map { "\(confirmTitle) \($0.lastPathComponent)" } ?? confirmTitle,
            canConfirm: !model.isBusy && model.selectedFile != nil,
            onConfirm: { pick(model.selectedFile) }
        ) {
            accessory(model)
        }
        .onAppear { model.browse(path: startPath) }
        .onChange(of: model.isBusy) {
            // A missing start folder (no ~/.ssh yet) opens home instead of an error.
            guard !model.isBusy, !triedStart else { return }
            triedStart = true
            if model.directory == nil, startPath != nil { model.browse(path: nil) }
        }
        .onDisappear { model.cancel() }
    }

    private func pick(_ url: URL?) {
        guard let url else { return }
        onPick(url)
        dismiss()
    }
}

extension WorkspaceFilePickerSheet where Accessory == EmptyView {
    init(title: String,
         fileSystem: any WorkspaceFileSystem,
         startPath: String? = nil,
         selectedFile: URL? = nil,
         showsHiddenFiles: Bool = false,
         emptyText: String = "No folders or files",
         accepts: @escaping (URL) -> Bool = { _ in true },
         confirmTitle: String = "Choose",
         onPick: @escaping (URL) -> Void) {
        self.init(title: title, fileSystem: fileSystem, startPath: startPath,
                  selectedFile: selectedFile, showsHiddenFiles: showsHiddenFiles,
                  emptyText: emptyText, accepts: accepts, confirmTitle: confirmTitle,
                  onPick: onPick) { _ in EmptyView() }
    }
}
