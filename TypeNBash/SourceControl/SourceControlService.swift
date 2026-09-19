import Foundation
import SwiftGitX

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
}

enum SourceControlAction: Sendable {
    case refresh
    case stage(String)
    case unstage(String)
    case commit(String)
    case fetch(String)
    case push(String)
}

/// Keeps libgit2 and filesystem work off the UI actor. Each operation opens its
/// own repository handle; no libgit2-backed objects escape into the views.
actor SourceControlService {
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

    func perform(_ action: SourceControlAction, in directory: URL) async throws -> SourceControlSnapshot {
        let root = try Self.repositoryRoot(in: directory)
        let repository = try Repository(at: root, createIfNotExists: false)
        switch action {
        case .refresh: break
        case .stage(let path): try repository.add(paths: [path])
        case .unstage(let path): try repository.restore(.staged, paths: [path])
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw SourceControlError.emptyMessage
            }
            try repository.commit(message: message)
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
            remotes: try repository.remote.list().map(\.name).sorted()
        )
    }
}

private enum SourceControlError: LocalizedError {
    case noRepository, emptyMessage
    var errorDescription: String? {
        switch self {
        case .noRepository: "This folder is not inside a Git repository. Open a local repository to use source control."
        case .emptyMessage: "Enter a commit message."
        }
    }
}

