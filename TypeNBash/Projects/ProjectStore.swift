//
//  ProjectStore.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/17/26.
//

import Foundation
import Observation

/// A saved working root — the narrow slice of a filesystem the user actually
/// wants in front of them, instead of a whole home directory.
///
/// A project names *where* to work, never *how to get there*: the connection is
/// referenced by `sshProfileID` so `SSHProfileStore` stays the single source of
/// truth for host, user, port, and key material. Editing a connection therefore
/// updates every project that opens over it, and the Keychain password — which
/// is keyed by profile id — keeps resolving without a second copy.
struct Project: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    /// Kept as a path rather than a `URL` because a remote root is a path on the
    /// far host, not a file URL this machine can resolve.
    var directoryPath: String
    /// `nil` marks a project on this Mac.
    var sshProfileID: UUID?
    var lastOpened: Date

    init(
        id: UUID = UUID(),
        name: String,
        directoryPath: String,
        sshProfileID: UUID? = nil,
        lastOpened: Date = .now
    ) {
        self.id = id
        self.name = name
        self.directoryPath = directoryPath
        self.sshProfileID = sshProfileID
        self.lastOpened = lastOpened
    }

    var isLocal: Bool { sshProfileID == nil }

    /// Only meaningful for a local project; a remote path is resolved on the host.
    var localDirectoryURL: URL {
        URL(fileURLWithPath: (directoryPath as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    /// The trailing folder name, for when the project name has been customized
    /// away from it and the real location still needs showing.
    var directoryName: String {
        URL(fileURLWithPath: directoryPath).lastPathComponent
    }
}

/// Where a project should be opened, once its connection has been looked up.
/// Resolving to this enum keeps the profile lookup out of the calling view.
enum ProjectTarget {
    case local(URL)
    case remote(SSHConnectionProfile, SSHAuthentication)
}

enum ProjectError: LocalizedError {
    case missingConnection(projectName: String)

    var errorDescription: String? {
        switch self {
        case .missingConnection(let projectName):
            "“\(projectName)” opens over a saved connection that no longer exists."
        }
    }
}

/// Persists the user's projects so a working root is chosen once and then
/// reopened from a list. Projects live in UserDefaults; nothing secret is stored
/// here, because the connection (and its Keychain password) belongs to
/// `SSHProfileStore`.
@MainActor
@Observable
final class ProjectStore {
    /// Most recently opened first, so this array is directly usable as the
    /// "Open Recent" ordering.
    private(set) var projects: [Project]

    private let defaults: UserDefaults
    private let storageKey = "TypeNBash.projects"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([Project].self, from: data) {
            projects = decoded.sorted { $0.lastOpened > $1.lastOpened }
        } else {
            projects = []
        }
    }

    /// Alphabetical view for a picker, where recency ordering would make the
    /// list jump around between openings.
    var alphabetized: [Project] {
        projects.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    var recents: [Project] {
        projects.sorted {
            $0.lastOpened.compare($1.lastOpened) == .orderedDescending }
    }

    // MARK: - Editing

    /// Inserts or updates the project, matched by id. The name and path are
    /// normalized here so callers can hand over raw field text.
    ///
    /// Returns the stored project, or `nil` if the directory path was blank.
    @discardableResult
    func save(_ project: Project) -> Project? {
        guard var normalized = Self.normalized(project) else { return nil }

        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            // Preserve the existing recency; only `markOpened` advances it.
            normalized.lastOpened = projects[index].lastOpened
            projects[index] = normalized
        } else {
            projects.insert(normalized, at: 0)
        }
        persist()
        return normalized
    }

    func delete(_ project: Project) {
        projects.removeAll { $0.id == project.id }
        persist()
    }

    /// Records that the project was just opened and re-sorts the recents.
    func markOpened(_ project: Project) {
        guard let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index].lastOpened = .now
        let touched = projects.remove(at: index)
        projects.insert(touched, at: 0)
        persist()
    }

    /// Builds a project for a directory, defaulting the name to the folder name
    /// the way an IDE titles a newly opened project.
    func makeProject(
        directoryPath: String,
        name: String? = nil,
        sshProfileID: UUID? = nil
    ) -> Project {
        let trimmedPath = directoryPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = URL(fileURLWithPath: trimmedPath).lastPathComponent
        let resolvedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Project(
            name: (resolvedName?.isEmpty == false ? resolvedName! : fallback),
            directoryPath: trimmedPath,
            sshProfileID: sshProfileID
        )
    }

    // MARK: - Lookup

    /// Finds an existing project for the same directory on the same connection,
    /// so opening a folder twice reuses its entry instead of duplicating it.
    func project(atDirectory path: String, sshProfileID: UUID? = nil) -> Project? {
        let target = Self.comparablePath(path, isLocal: sshProfileID == nil)
        return projects.first {
            $0.sshProfileID == sshProfileID
                && Self.comparablePath($0.directoryPath, isLocal: $0.isLocal) == target
        }
    }

    /// Projects that would break if this connection were deleted. Lets the SSH
    /// UI warn before removing a profile that projects still point at.
    func projects(referencing sshProfileID: UUID) -> [Project] {
        projects.filter { $0.sshProfileID == sshProfileID }
    }

    // MARK: - Resolution

    /// Turns a project into something openable, looking up its connection and
    /// saved password.
    ///
    /// The project's directory wins over the profile's own `remoteRoot`: the
    /// profile says which machine, the project says which folder on it.
    func resolve(
        _ project: Project,
        using profileStore: SSHProfileStore
    ) throws -> ProjectTarget {
        guard let sshProfileID = project.sshProfileID else {
            return .local(project.localDirectoryURL)
        }
        guard var profile = profileStore.profiles.first(where: { $0.id == sshProfileID }) else {
            throw ProjectError.missingConnection(projectName: project.name)
        }
        profile.remoteRoot = project.directoryPath

        // Mirrors the connection sheet: a remembered password implies password
        // auth, otherwise fall back to key or agent credentials.
        let authentication: SSHAuthentication =
            if let saved = profileStore.password(for: sshProfileID) {
                .password(saved)
            } else {
                .keyOrAgent
            }
        return .remote(profile, authentication)
    }

    // MARK: - Storage

    private func persist() {
        guard let data = try? JSONEncoder().encode(projects) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Trims the fields and expands a local path, so two spellings of the same
    /// local folder don't read as different projects.
    private static func normalized(_ project: Project) -> Project? {
        var copy = project
        copy.directoryPath = project.directoryPath
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !copy.directoryPath.isEmpty else { return nil }

        if copy.isLocal {
            copy.directoryPath = copy.localDirectoryURL.path(percentEncoded: false)
        }

        let trimmedName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
        copy.name = trimmedName.isEmpty ? copy.directoryName : trimmedName
        return copy
    }

    /// A remote filesystem may be case-sensitive, and a leftover trailing slash
    /// shouldn't fork a project in two.
    private static func comparablePath(_ path: String, isLocal: Bool) -> String {
        var resolved = path.trimmingCharacters(in: .whitespacesAndNewlines)
        if isLocal {
            resolved = URL(fileURLWithPath: (resolved as NSString).expandingTildeInPath)
                .standardizedFileURL
                .path(percentEncoded: false)
        }
        while resolved.count > 1, resolved.hasSuffix("/") {
            resolved.removeLast()
        }
        return resolved
    }
}
