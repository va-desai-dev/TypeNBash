import Foundation
import Observation

@MainActor
@Observable
final class GitDiffModel {
    let directory: URL
    var scope = GitDiffScope.all
    private(set) var selectedPath: String?
    private(set) var result: GitDiffResult?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private let service = GitDiffService()
    private var generation = 0

    init(directory: URL, selectedFile: URL?) {
        self.directory = directory
        selectedPath = selectedFile?.path
    }

    func select(_ path: String?) {
        guard let path, selectedPath != path else { return }
        selectedPath = path
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
            let loaded = try await service.load(directory: directory, scope: requestedScope, selectedPath: requestedPath)
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
