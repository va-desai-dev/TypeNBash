import Foundation
import Observation

@MainActor
@Observable
final class GitDiffModel {
    let directory: URL
    private(set) var scope = GitDiffScope.all
    private(set) var selectedPath: String?
    private(set) var result: GitDiffResult?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private let service = GitDiffService()
    /// Set for an SSH workspace, whose repository lives on the host.
    private let remote: RemoteGit?
    private var generation = 0

    init(directory: URL, selectedFile: URL?, remote: RemoteGit? = nil) {
        self.directory = directory
        self.remote = remote
        selectedPath = selectedFile?.path
    }

    /// Both writable pieces of state reload the comparison themselves, so a
    /// view can bind straight to them without also having to remember an
    /// `onChange` that calls `refresh()`.
    func select(_ path: String?) {
        guard let path, selectedPath != path else { return }
        selectedPath = path
        Task { await refresh() }
    }

    func setScope(_ scope: GitDiffScope) {
        guard self.scope != scope else { return }
        self.scope = scope
        Task { await refresh() }
    }

    func refresh() async {
        generation &+= 1
        let request = generation
        let requestedScope = scope
        let requestedPath = selectedPath
        isLoading = true
        errorMessage = nil
        do {
            let loaded = if let remote {
                try await remote.diff(directory: directory, scope: requestedScope, selectedPath: requestedPath)
            } else {
                try await service.load(directory: directory, scope: requestedScope, selectedPath: requestedPath)
            }
            guard request == generation else { return }
            result = loaded
            selectedPath = loaded.selectedPath
        } catch {
            guard request == generation else { return }
            result = nil
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }
}
