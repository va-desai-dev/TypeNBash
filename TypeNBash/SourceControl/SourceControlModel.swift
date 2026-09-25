import Foundation
import Observation

@MainActor
@Observable
final class SourceControlModel {
    let directory: URL
    /// Set for an SSH workspace, whose repository lives on the host.
    let remote: RemoteGit?
    let account = GitHubAccountModel()
    private let service = SourceControlService()
    private(set) var snapshot: SourceControlSnapshot?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var resultMessage: String?
    var commitMessage = ""
    var selectedRemote = ""

    /// Whether this remote host may borrow this Mac's GitHub sign-in — here and
    /// in its consoles. See `GitHubLending`.
    var lendsGitHubSignIn: Bool {
        didSet {
            guard let id = remote?.profileID else { return }
            GitHubLending.setEnabled(lendsGitHubSignIn, for: id)
        }
    }

    init(directory: URL, remote: RemoteGit? = nil) {
        self.directory = directory
        self.remote = remote
        lendsGitHubSignIn = remote?.profileID.map(GitHubLending.isEnabled(for:)) ?? false
    }

    private func perform(_ action: SourceControlAction) async throws -> SourceControlSnapshot {
        if let remote {
            return try await remote.perform(action, in: directory, lendsGitHubSignIn: lendsGitHubSignIn)
        }
        return try await service.perform(action, in: directory)
    }

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
            snapshot = try await perform(action)
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
            if case GitHubDeviceFlowError.signInAgain = error { GitHubSignInStatus.shared.markExpired() }
            errorMessage = error.localizedDescription
            // A failed operation may have partially changed the index or refs.
            snapshot = try? await perform(.refresh)
        }
    }
}
