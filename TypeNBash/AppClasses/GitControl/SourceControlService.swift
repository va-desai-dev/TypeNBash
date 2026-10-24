import Foundation
import SwiftGitX

extension Notification.Name {
    static let editorGitBaselineDidChange = Notification.Name("editorGitBaselineDidChange")
    /// Posted after the app stages, commits, fetches, pushes, switches or
    /// merges, with the model that did it as the object, so every view of the
    /// repository — Changes, Repositories, the sidebar footer — reloads.
    static let gitRepositoryDidChange = Notification.Name("gitRepositoryDidChange")
}

struct SourceControlChange: Identifiable, Sendable {
    let path: String
    let staged: Bool
    let unstaged: Bool
    let conflicted: Bool
    var id: String { path }
}

struct SourceControlSnapshot: Sendable {
    let root: URL
    let branch: String
    let detached: Bool
    let unborn: Bool
    let changes: [SourceControlChange]
    let remotes: [String]
    var identity: SourceControlIdentity? = nil
}

nonisolated struct SourceControlIdentity: Equatable, Sendable {
    var name = ""
    var email = ""
    var isComplete: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func fillingMissingValues(from fallback: Self?) -> Self {
        Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback?.name ?? name : name,
             email: email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallback?.email ?? email : email)
    }

    func validated() throws -> Self {
        let value = Self(name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                         email: email.trimmingCharacters(in: .whitespacesAndNewlines))
        guard value.isComplete else { throw SourceControlError.missingIdentity }
        let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "<>"))
        guard value.name.rangeOfCharacter(from: forbidden) == nil,
              value.email.rangeOfCharacter(from: forbidden.union(.whitespacesAndNewlines)) == nil else {
            throw SourceControlError.invalidIdentity
        }
        return value
    }
}

enum SourceControlAction: Sendable {
    case refresh
    case stage(String)
    case stageAll([String])
    case unstage(String)
    case unstageAll([String])
    case commit(String)
    case fetch(String)
    case push(String)
}

/// Keeps libgit2 and filesystem work off the UI actor. Each operation opens its
/// own repository handle; no libgit2-backed objects escape into the views.
actor SourceControlService {
    /// Only repository config is written. This also works when the sandbox
    /// cannot read the user's global ~/.gitconfig.
    func saveIdentity(_ identity: SourceControlIdentity, in directory: URL) async throws -> SourceControlSnapshot {
        let identity = try identity.validated()
        let root = try Self.repositoryRoot(in: directory)
        let repository = try Repository(at: root, createIfNotExists: false)
        try repository.config.set("user.name", to: identity.name)
        try repository.config.set("user.email", to: identity.email)
        return try await perform(.refresh, in: directory)
    }

    func identity(in repository: Repository) throws -> SourceControlIdentity {
        func value(_ key: String) throws -> String {
            do { return try repository.config.string(forKey: key) ?? "" }
            catch where error.code == .notFound { return "" }
        }
        return try SourceControlIdentity(name: value("user.name"), email: value("user.email"))
    }

    nonisolated static func repositoryRoot(in directory: URL) throws -> URL {
        var root = directory.standardizedFileURL
        while !FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path) {
            let parent = root.deletingLastPathComponent().standardizedFileURL
            guard !root.path.isEmpty, root.path != "/", parent.path != root.path else {
                throw SourceControlError.noRepository
            }
            root = parent
        }
        return root
    }

    func perform(_ action: SourceControlAction, in directory: URL,
                 defaultIdentity: SourceControlIdentity? = nil) async throws -> SourceControlSnapshot {
        let root = try Self.repositoryRoot(in: directory)
        let repository = try Repository(at: root, createIfNotExists: false)
        switch action {
        case .refresh: break
        case .stage(let path): try repository.add(paths: [path])
        case .stageAll(let paths): try repository.add(paths: paths)
        case .unstageAll(let paths): try repository.restore(.staged, paths: paths)
        case .unstage(let path): try repository.restore(.staged, paths: [path])
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceControlError.emptyMessage
            }
            let configured = try identity(in: repository)
            let resolved = try configured.fillingMissingValues(from: defaultIdentity).validated()
            // Only fill missing fields, and only at commit time. Existing Git
            // config (including global config when accessible) takes precedence.
            if configured.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try repository.config.set("user.name", to: resolved.name)
            }
            if configured.email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try repository.config.set("user.email", to: resolved.email)
            }
            try repository.commit(message: message)
            try GitMerge.finishCommit(root: root)
            await MainActor.run {
                NotificationCenter.default.post(name: .editorGitBaselineDidChange, object: nil)
            }
        case .push(let name):
            let remote = try repository.remote.get(named: name)
            let credential = remote.url.host?.lowercased() == "github.com"
                ? try await GitHubAuthenticationService.shared.validCredential() : nil
            try GitHubTransport.push(root: root, remote: name, credential: credential)
        case .fetch(let name):
            let remote = try repository.remote.get(named: name)
            if remote.url.host?.lowercased() == "github.com" {
                guard GitHubCredentialContext.accepts(remote.url) else {
                    throw GitHubAuthenticationError.unsafeRemote
                }
                if let credential = try await GitHubAuthenticationService.shared.validCredential() {
                    try GitHubTransport.fetch(root: root, remote: name, credential: credential)
                } else {
                    try await repository.fetch(remote: remote)
                }
            } else {
                // GitHub credentials are never offered to another host.
                try await repository.fetch(remote: remote)
            }
        }
        let changes = try repository.status().compactMap { entry -> SourceControlChange? in
            guard let path = entry.workingTree?.newFile.path ?? entry.index?.newFile.path else { return nil }
            return SourceControlChange(
                path: path,
                staged: entry.index != nil,
                unstaged: entry.workingTree != nil,
                conflicted: entry.status.contains(.conflicted)
            )
        }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        return SourceControlSnapshot(
            root: try repository.workingDirectory,
            branch: repository.isHEADUnborn ? "No commits yet" : try repository.HEAD.name,
            detached: repository.isHEADDetached,
            unborn: repository.isHEADUnborn,
            changes: changes,
            remotes: try repository.remote.list().map(\.name).sorted(),
            identity: try identity(in: repository)
        )
    }
}

private enum SourceControlError: LocalizedError {
    case noRepository, emptyMessage, missingIdentity, invalidIdentity
    var errorDescription: String? {
        switch self {
        case .noRepository: "This folder is not inside a Git repository. Open a local repository to use source control."
        case .emptyMessage: "Enter a commit message."
        case .missingIdentity: "Set your commit name and email in Commit Identity or save an app default in Settings → Source Control. GitHub sign-in does not set the Git author identity."
        case .invalidIdentity: "Commit identity cannot contain line breaks or angle brackets, and the email cannot contain spaces."
        }
    }
}
