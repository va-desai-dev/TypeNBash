import Foundation
import Observation

@MainActor
@Observable
final class SourceControlModel {
    let directory: URL
    let account = GitHubAccountModel()
    private let service = SourceControlService()
    private(set) var snapshot: SourceControlSnapshot?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var resultMessage: String?
    var commitMessage = ""
    var selectedRemote = ""

    init(directory: URL) { self.directory = directory }

    var canCommit: Bool {
        !isBusy && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && snapshot?.changes.contains(where: \.staged) == true
            && snapshot?.changes.contains(where: \.conflicted) == false
    }

    func run(_ action: SourceControlAction) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        resultMessage = nil
        defer { isBusy = false }
        do {
            snapshot = try await service.perform(action, in: directory)
            if let remotes = snapshot?.remotes, !remotes.contains(selectedRemote) {
                selectedRemote = remotes.contains("origin") ? "origin" : (remotes.first ?? "")
            }
            switch action {
            case .commit:
                commitMessage = ""
                resultMessage = "Commit saved locally. Use Push to publish it to the selected remote."
            case .push(let remote): resultMessage = "Pushed to \(remote)."
            case .fetch: resultMessage = "Fetch completed."
            default: break
            }
        } catch {
            errorMessage = error.localizedDescription
            // A failed operation may have partially changed the index or refs.
            snapshot = try? await service.perform(.refresh, in: directory)
        }
    }
}
