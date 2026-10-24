import SwiftUI
import BibTeXViewer

/// Browses the project's workspace for a .bib to cite from, or creates a new
/// one in the folder being shown. Uses the same file system as the project,
/// so it works the same way for a remote project as for a local one.
@MainActor
@Observable
final class BibFilePickerModel {
    var showsHiddenFiles = false
    var selectedFile: URL?
    var newFileName = ""
    private(set) var directory: URL?
    private(set) var entries: [WorkspaceFileEntry] = []
    private(set) var isBusy = false
    private(set) var error: String?

    private let fileSystem: any WorkspaceFileSystem
    private var task: Task<Void, Never>?
    private var generation = 0

    init(fileSystem: any WorkspaceFileSystem) {
        self.fileSystem = fileSystem
    }

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
            // Folders first, then the .bib files a project could cite from.
            entries = listed
                .filter { $0.isDirectory || $0.url.pathExtension.lowercased() == "bib" }
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

    /// Creates an empty .bib in the folder being shown. Never overwrites.
    func createFile(then completion: @escaping (URL) -> Void) {
        guard let directory else { return }
        var name = newFileName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.lowercased().hasSuffix(".bib") { name += ".bib" }
        run { [self] in
            try ProjectManifest.validateFolderName(name)
            let url = directory.appendingPathComponent(name).standardizedFileURL
            try await fileSystem.createFile(Data(), at: url)
            newFileName = ""
            completion(url)
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
