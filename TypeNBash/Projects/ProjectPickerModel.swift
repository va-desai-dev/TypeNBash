import Foundation
import Observation

/// Owns project selection and temporary SSH browsing without changing the window.
@MainActor
@Observable
final class ProjectPickerModel {
    let store: ProjectStore
    let session: WindowSession
    let profiles: SSHProfileStore
    enum SetupMode: String, CaseIterable, Identifiable {
        case newFolder = "Create new folder"
        case initializeFolder = "Initialize existing folder"
        case openFolder = "Open existing folder"
        var id: Self { self }
    }

    var setupMode = SetupMode.openFolder
    var outputDirectory = "output"
    var name = ""
    var directoryPath = ""
    var selectedProfileID: UUID?
    var password = ""
    var showsHiddenFiles = false
    private(set) var folders: [WorkspaceFileEntry] = []
    private(set) var browsedDirectory: URL?
    private(set) var error: String?
    private(set) var isBusy = false
    var isBrowsing = false
    private var browsingBackend: SSHWorkspaceBackend?
    private var ownsBackend = false
    private var task: Task<Void, Never>?
    private var generation = 0

    init(session: WindowSession, profiles: SSHProfileStore, store: ProjectStore? = nil) {
        self.store = store ?? .shared
        self.session = session
        self.profiles = profiles
        if case .ssh(let profile) = session.location {
            selectedProfileID = profile.id
        }
    }

    var availableProfiles: [SSHConnectionProfile] {
        var result = profiles.profiles
        if case .ssh(let active) = session.location,
           !result.contains(where: { $0.id == active.id }) {
            result.append(active)
        }
        return result
    }

    var canOpen: Bool {
        !directoryPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !isBusy
            && (setupMode != .newFolder || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    func locationChanged() {
        cancel()
        directoryPath = ""
        password = ""
        error = nil
        browsedDirectory = nil
        folders = []
        isBrowsing = false
    }

    func chooseFolder() {
        isBrowsing = true
        let initialPath = selectedProfileID == nil && session.location == .local
            ? session.fileBrowser.directory.path(percentEncoded: false) : nil
        browse(path: directoryPath.isEmpty ? initialPath : directoryPath)
    }

    func browse(path: String? = nil) {
        run { [self] in
            let fileSystem: any WorkspaceFileSystem
            let directory: URL
            if selectedProfileID == nil {
                fileSystem = LocalWorkspaceFileSystem()
                let expandedPath = ((path ?? fileSystem.homeDirectory.path) as NSString).expandingTildeInPath
                directory = URL(fileURLWithPath: expandedPath).standardizedFileURL.resolvingSymlinksInPath()
            } else {
                let backend = try await remoteBackend()
                fileSystem = backend.fileSystem
                directory = try await backend.resolveRemotePath(path ?? fileSystem.homeDirectory.path)
            }
            let entries = try await fileSystem.contentsOfDirectory(
                at: directory, includingHiddenFiles: showsHiddenFiles
            )
            try Task.checkCancellation()
            browsedDirectory = directory
            folders = entries.filter(\.isDirectory).sorted {
                $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
            }
        }
    }

    func useBrowsedFolder() {
        guard let browsedDirectory, !isBusy, error == nil else { return }
        directoryPath = browsedDirectory.path(percentEncoded: false)
        isBrowsing = false
    }

    func label(for project: Project) -> String {
        guard let id = project.sshProfileID else { return "This Mac" }
        return availableProfiles.first(where: { $0.id == id })?.destination ?? "Missing SSH connection"
    }

    func openSaved(_ project: Project, completion: @escaping () -> Void) {
        if selectedProfileID != project.sshProfileID {
            selectedProfileID = project.sshProfileID
            locationChanged()
        }
        name = project.name
        directoryPath = project.directoryPath
        open(project, mode: .openFolder, completion: completion)
    }

    func saveAndOpen(completion: @escaping () -> Void) {
        guard canOpen else { return }
        var project = store.project(atDirectory: directoryPath, sshProfileID: selectedProfileID)
            ?? store.makeProject(directoryPath: directoryPath, name: name, sshProfileID: selectedProfileID)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedName.isEmpty { project.name = trimmedName }
        open(project, mode: setupMode, completion: completion)
    }

    private func open(_ project: Project, mode: SetupMode, completion: @escaping () -> Void) {
        run { [self] in
            var opened = project
            let backend = project.sshProfileID == nil ? nil : try await remoteBackend()
            let fileSystem: any WorkspaceFileSystem = backend?.fileSystem ?? LocalWorkspaceFileSystem()
            // A definition can also be opened by entering its path in the picker.
            let opensDefinition = project.directoryPath.hasSuffix("/" + ProjectManifest.filename)
            let input = opensDefinition
                ? URL(fileURLWithPath: project.directoryPath).deletingLastPathComponent().path
                : project.directoryPath
            var root = if let backend {
                try await backend.resolveRemotePath(input)
            } else {
                URL(fileURLWithPath: (input as NSString).expandingTildeInPath).standardizedFileURL.resolvingSymlinksInPath()
            }
            try Task.checkCancellation()
            if mode == .newFolder {
                let entries = try await fileSystem.contentsOfDirectory(at: root, includingHiddenFiles: true)
                try Task.checkCancellation()
                let folderName = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                try ProjectManifest.validateFolderName(folderName)
                guard !entries.contains(where: { $0.url.lastPathComponent == folderName }) else {
                    throw ProjectSetupError.invalid("A file or folder named ‘\(folderName)’ already exists. Choose another name or open that folder.")
                }
                // Validate all settings before creating any files.
                try ProjectManifest(name: folderName, outputDirectory: outputDirectory).validate()
                root.appendPathComponent(folderName, isDirectory: true)
                try await fileSystem.createDirectory(at: root)
            }
            var manifest = try await ProjectManifest.load(in: root, fileSystem: fileSystem)
            if opensDefinition, manifest == nil {
                throw ProjectSetupError.invalid("No project definition exists at this path.")
            }
            if mode != .openFolder {
                guard manifest == nil else {
                    throw ProjectSetupError.invalid("This folder already has a project definition. Use Open existing folder.")
                }
                let definition = ProjectManifest(name: project.name, outputDirectory: outputDirectory)
                try await definition.create(in: root, fileSystem: fileSystem)
                manifest = definition
            }
            try Task.checkCancellation()
            opened.directoryPath = root.path(percentEncoded: false)
            if let existing = store.project(atDirectory: opened.directoryPath, sshProfileID: opened.sshProfileID) {
                opened = existing
            } else if mode == .newFolder {
                opened = store.makeProject(directoryPath: opened.directoryPath, name: project.name, sshProfileID: project.sshProfileID)
            }
            opened.manifest = manifest
            opened.name = manifest?.name ?? project.name
            if let backend, let id = project.sshProfileID {
                try session.openRemoteProject(opened, backend: backend, root: root)
                ownsBackend = false
                browsingBackend = nil
                if !profiles.profiles.contains(where: { $0.id == id }),
                   case .ssh(let profile) = session.location {
                    profiles.save(profile, password: nil)
                }
            } else {
                await session.open(opened, at: .local(root))
            }
            if let saved = store.save(opened) { store.markOpened(saved) }
            password = ""
            completion()
        }
    }

    private func remoteBackend() async throws -> SSHWorkspaceBackend {
        if let browsingBackend { return browsingBackend }
        guard let profile = availableProfiles.first(where: { $0.id == selectedProfileID }) else {
            throw ProjectError.missingConnection(projectName: name)
        }
        if let active = session.projectBackend(for: profile) {
            browsingBackend = active
            ownsBackend = false
            return active
        }
        var browsingProfile = profile
        browsingProfile.remoteRoot = nil
        let secret = password.isEmpty ? profiles.password(for: profile.id) : password
        let backend = SSHWorkspaceBackend(
            profile: browsingProfile,
            authentication: secret.map(SSHAuthentication.password) ?? .keyOrAgent
        )
        do {
            try await backend.connect()
            try Task.checkCancellation()
            browsingBackend = backend
            ownsBackend = true
            return backend
        } catch {
            backend.disconnect()
            throw error
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
        if ownsBackend { browsingBackend?.disconnect() }
        browsingBackend = nil
        ownsBackend = false
        isBusy = false
    }
}
