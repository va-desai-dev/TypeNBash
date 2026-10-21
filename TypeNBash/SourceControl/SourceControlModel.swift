import Foundation
import Observation
import SwiftGitX

@MainActor
@Observable
final class SourceControlModel {
    let directory: URL
    /// Set for an SSH workspace, whose repository lives on the host.
    let remote: RemoteGit?
    let account = GitHubAccountModel()
    let identitySettings: SourceControlIdentitySettings
    private let service = SourceControlService()
    private(set) var snapshot: SourceControlSnapshot?
    private(set) var isBusy = false
    private(set) var errorMessage: String?
    private(set) var resultMessage: String?
    var commitMessage = ""
    var selectedRemote = ""
    var identityDraft = SourceControlIdentity()
    var rememberIdentity = false
    private(set) var isEditingIdentity = false
    var effectiveIdentity: SourceControlIdentity? {
        snapshot?.identity?.fillingMissingValues(from: identitySettings.identity)
    }
    var needsIdentity: Bool { remote == nil && effectiveIdentity?.isComplete == false }
    var canSaveIdentity: Bool { !isBusy && (try? identityDraft.validated()) != nil }

    func editIdentity() {
        identityDraft = effectiveIdentity ?? SourceControlIdentity()
        rememberIdentity = false
        isEditingIdentity = true
    }

    func cancelIdentityEditing() { isEditingIdentity = false }

    func saveIdentity() async {
        guard remote == nil, canSaveIdentity else { return }
        isBusy = true; errorMessage = nil; resultMessage = nil
        defer { isBusy = false }
        do {
            snapshot = try await service.saveIdentity(identityDraft, in: directory)
            identityDraft = snapshot?.identity ?? identityDraft
            if rememberIdentity { try identitySettings.setIdentity(identityDraft) }
            isEditingIdentity = false
            resultMessage = rememberIdentity
                ? "Commit identity saved for this repository and as the app default."
                : "Commit identity saved for this repository. You can now commit your staged changes."
        } catch { report(error) }
    }

    /// Whether this remote host may borrow this Mac's GitHub sign-in — here and
    /// in its consoles. See `GitHubLending`.
    var lendsGitHubSignIn: Bool {
        didSet {
            guard let id = remote?.profileID else { return }
            GitHubLending.setEnabled(lendsGitHubSignIn, for: id)
        }
    }

    init(directory: URL, remote: RemoteGit? = nil,
         identitySettings: SourceControlIdentitySettings? = nil) {
        self.directory = directory
        self.remote = remote
        self.identitySettings = identitySettings ?? .shared
        lendsGitHubSignIn = remote?.profileID.map(GitHubLending.isEnabled(for:)) ?? false
    }

    private func perform(_ action: SourceControlAction) async throws -> SourceControlSnapshot {
        if let remote {
            return try await remote.perform(action, in: directory, lendsGitHubSignIn: lendsGitHubSignIn)
        }
        return try await service.perform(action, in: directory, defaultIdentity: identitySettings.identity)
    }

    var canCommit: Bool {
        !isBusy && !commitMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !needsIdentity && !isEditingIdentity
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
            if needsIdentity && !isEditingIdentity { editIdentity() }
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
            report(error)
            // A failed operation may have partially changed the index or refs.
            snapshot = try? await perform(.refresh)
            if needsIdentity && !isEditingIdentity { editIdentity() }
        }
    }

    private func report(_ error: Error) {
        // SwiftGitXError doesn't conform to LocalizedError.
        errorMessage = (error as? SwiftGitXError).map { "Git: " + $0.message } ?? error.localizedDescription
    }
}
