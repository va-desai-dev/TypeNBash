import Foundation
import Observation

/// What a window is currently hosting, as opposed to `AppStartupModes`, which
/// is the launch *intent* chosen in the welcome window and collapses
/// `.projectNew` and `.projectOpen` onto the same outcome. This is the outcome,
/// and it is derived rather than stored so it follows a dropped SSH connection
/// or a closed project instead of going stale.
enum WorkspaceMode: String, CaseIterable, Identifiable, Hashable, Sendable {
    /// Free roaming on this Mac: no project root and no host.
    case home = "Home"
    /// Scoped to a project root, local or remote.
    case project = "Project"
    /// Connected to an SSH host without a project scope.
    case remote = "SSH"

    var id: Self { self }
}

@MainActor
@Observable
final class WindowSession {
    enum State: Equatable {
        case local
        case connecting(SSHConnectionProfile)
        case remote(SSHConnectionProfile)
        case failed(SSHConnectionProfile, String)
    }

    private(set) var state: State
    private(set) var location: WorkspaceLocation
    private(set) var rootDirectory: URL
    private(set) var fileBrowser: FileBrowserModel
    /// How the terminal for the current workspace should be launched. Replaced
    /// wholesale on every backend transition, so the view can key off it.
    private(set) var terminalConfiguration: TerminalLaunchConfiguration

    /// Identifies the terminal and all callbacks belonging to this backend.
    private(set) var terminalGeneration = 0
    private(set) var terminalHost: String?

    /// The project this window was opened for, if any. Retained because
    /// `rootDirectory` alone can't survive a shell exit: the window would
    /// otherwise re-root at whatever directory the terminal was last in.
    private(set) var activeProject: Project? {
        didSet {
            fileBrowser.navigationRoot = activeProject == nil ? nil : rootDirectory
        }
    }

    /// A project outranks where it lives, so a project opened over SSH is
    /// still `.project`; `.remote` means a host with no project scope.
    var mode: WorkspaceMode {
        if activeProject != nil { return .project }
        return location == .local ? .home : .remote
    }

    private var localDirectory: URL

    private var backend: any WorkspaceBackend
    private var transitionGeneration = 0
    private var lastTerminalRestart: Date?

    init(localRoot: URL = FileManager.default.homeDirectoryForCurrentUser) {
        let localBackend = LocalWorkspaceBackend(rootDirectory: localRoot)
        localDirectory = localRoot
        backend = localBackend
        state = .local
        location = .local
        rootDirectory = localRoot
        terminalConfiguration = localBackend.makeTerminalConfiguration()
        fileBrowser = FileBrowserModel(fileSystem: localBackend.fileSystem)
        fileBrowser.navigate(to: localRoot)
    }

    /// Connects the entire window to one SSH workspace. The current backend is
    /// retained until the remote connection and root directory are both valid.
    @discardableResult
    func connect(
        to profile: SSHConnectionProfile,
        authentication: SSHAuthentication = .keyOrAgent
    ) async -> Bool {
        transitionGeneration &+= 1
        let generation = transitionGeneration
        // Preserve the current project until a replacement connection succeeds.
        let retainedState: State
        switch location {
        case .local:
            retainedState = .local
        case .ssh(let activeProfile):
            retainedState = .remote(activeProfile)
        }
        state = .connecting(profile)
        let remoteBackend = SSHWorkspaceBackend(
            profile: profile,
            authentication: authentication
        )

        do {
            try await remoteBackend.connect()
            guard generation == transitionGeneration else {
                remoteBackend.disconnect()
                return false
            }
            try Task.checkCancellation()
            try adopt(remoteBackend)
            state = .remote(profile)
            activeProject = nil
            return true
        } catch {
            remoteBackend.disconnect()
            if generation == transitionGeneration {
                if error is CancellationError {
                    state = retainedState
                } else {
                    state = .failed(profile, error.localizedDescription)
                }
            }
            return false
        }
    }

    /// Opens a project as the window's workspace, retaining it so the root
    /// outlives the shell that happens to be running in it.
    ///
    /// The target is resolved by the caller, which keeps the SSH profile (and
    /// Keychain) lookup out of the session.
    func open(_ project: Project, at target: ProjectTarget) async {
        switch target {
        case .local(let url):
            disconnectToLocal(rootDirectory: url)
            activeProject = project

        case .remote(let profile, let authentication):
            let connected = await connect(to: profile, authentication: authentication)
            // A failed connection leaves the window where it was, so the
            // project never became the active one.
            if connected {
                activeProject = project
            }
        }
    }

    /// Borrow the current connection so password-only sessions can browse without reauthenticating.
    func projectBackend(for profile: SSHConnectionProfile) -> SSHWorkspaceBackend? {
        guard case .ssh(var current) = location else { return nil }
        var requested = profile
        current.remoteRoot = nil
        requested.remoteRoot = nil
        guard current == requested else { return nil }
        return backend as? SSHWorkspaceBackend
    }

    func openRemoteProject(_ project: Project, backend remote: SSHWorkspaceBackend, root: URL) throws {
        let previousRoot = remote.rootDirectory
        remote.setProjectRoot(root)
        do {
            try adopt(remote)
        } catch {
            remote.setProjectRoot(previousRoot)
            throw error
        }
        transitionGeneration &+= 1
        if case .ssh(let profile) = location { state = .remote(profile) }
        var resolved = project
        resolved.directoryPath = root.path(percentEncoded: false)
        activeProject = resolved
    }

    /// Returns the whole window to a fresh local workspace context.
    ///
    /// A nil `rootDirectory` means an implicit return (the shell exited or is
    /// being restarted), which must land back at the open project's root rather
    /// than at whatever directory the terminal was last in.
    func disconnectToLocal(
        rootDirectory: URL? = nil
    ) {
        transitionGeneration &+= 1
        if rootDirectory != nil || activeProject?.isLocal == false {
            activeProject = nil
        }
        let fallbackRoot = activeProjectLocalRoot ?? localDirectory
        let localBackend = LocalWorkspaceBackend(rootDirectory: rootDirectory ?? fallbackRoot)
        do {
            try adopt(localBackend)
            localDirectory = localBackend.rootDirectory
            state = .local
        } catch {
            // Local construction has no throwing operations today. Keeping this
            // branch prevents a future backend failure from destroying the active one.
        }
    }

    /// Stops treating the window as scoped to a project, releasing the root
    /// boundary without moving the workspace.
    func closeProject() {
        activeProject = nil
    }

    private var activeProjectLocalRoot: URL? {
        guard let activeProject, activeProject.isLocal else { return nil }
        return activeProject.localDirectoryURL
    }

    /// Shared destination for future export actions. Created only when an export asks for it.
    func prepareProjectOutputDirectory() async throws -> URL {
        guard let project = activeProject else {
            throw ProjectSetupError.invalid("Open a project before exporting project files.")
        }
        let name = project.manifest?.outputDirectory ?? "output"
        try ProjectManifest.validateFolderName(name)
        let root = rootDirectory
        let currentBackend = backend
        let generation = terminalGeneration
        let target = root.appendingPathComponent(name, isDirectory: true)
        let entries = try await currentBackend.fileSystem.contentsOfDirectory(at: root, includingHiddenFiles: true)
        try Task.checkCancellation()
        guard generation == terminalGeneration, activeProject?.id == project.id else { throw CancellationError() }
        if let existing = entries.first(where: { $0.url.lastPathComponent == name }) {
            guard existing.isDirectory else { throw ProjectSetupError.invalid("The output path is already a file.") }
        } else {
            try await currentBackend.fileSystem.createDirectory(at: target)
        }
        let resolvedRoot: URL
        let resolvedTarget: URL
        if let remote = currentBackend as? SSHWorkspaceBackend {
            resolvedRoot = try await remote.resolveRemotePath(root.path)
            resolvedTarget = try await remote.resolveRemotePath(target.path)
        } else {
            resolvedRoot = root.resolvingSymlinksInPath()
            resolvedTarget = target.resolvingSymlinksInPath()
        }
        guard resolvedTarget.pathComponents.starts(with: resolvedRoot.pathComponents),
              resolvedTarget.pathComponents.count > resolvedRoot.pathComponents.count else {
            throw ProjectSetupError.invalid("The output folder must resolve inside the project directory.")
        }
        try Task.checkCancellation()
        guard generation == terminalGeneration, activeProject?.id == project.id else { throw CancellationError() }
        return resolvedTarget
    }

    func streamTelemetry(to monitor: SystemMonitor) async {
        switch location {
        case .local:
            try? await backend.applyTelemetry(to: monitor)
        case .ssh:
            monitor.useRemoteTelemetry(reset: true)
            while !Task.isCancelled {
                do {
                    try await backend.applyTelemetry(to: monitor)
                } catch {
                    guard !Task.isCancelled else { return }
                    monitor.isConnected = false
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func close() {
        transitionGeneration &+= 1
        terminalGeneration &+= 1
        backend.disconnect()
    }

    /// Directory reports may update only the backend that launched their shell.
    /// A host report is never permission to create or switch SSH connections.
    func terminalReported(host: String?, directory: URL, generation: Int) {
        guard generation == terminalGeneration else { return }
        if let host, !host.isEmpty {
            let normalized = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if let known = terminalHost, known != normalized { return }
            terminalHost = normalized
        }
        // The project navigator and editor are independent of the console's PWD.
        // Following shell reports here would discard the selected file and draft.
        guard activeProject == nil else { return }

        if location == .local { localDirectory = directory }
        // Every prompt reports PWD. Reopening the same folder would erase an
        // editor selection or unsaved buffer after each terminal command.
        guard fileBrowser.directory.standardizedFileURL != directory.standardizedFileURL else { return }
        fileBrowser.navigate(to: directory)
    }

    /// A managed SSH shell owns the window's remote lifetime. `exit`, Ctrl-D,
    /// or a lost connection all return to the previous local directory.
    func handleTerminalExit(generation: Int) {
        guard generation == terminalGeneration else { return }
        let now = Date()
        if location == .local, let last = lastTerminalRestart,
           now.timeIntervalSince(last) < 1 { return }
        lastTerminalRestart = now
        if activeProject?.isLocal == true {
            // Restart only the console. Re-adopting the backend resets the navigator
            // and discards the project's open file or unsaved draft.
            terminalGeneration &+= 1
            terminalHost = nil
        } else {
            disconnectToLocal()
        }
    }

    private func adopt(
        _ newBackend: any WorkspaceBackend
    ) throws {
        // Validate the new terminal configuration before tearing down the active backend.
        let newConfiguration = try newBackend.makeTerminalConfiguration()

        if backend !== newBackend { backend.disconnect() }

        backend = newBackend
        location = newBackend.location
        rootDirectory = newBackend.rootDirectory
        terminalConfiguration = newConfiguration
        fileBrowser.use(
            fileSystem: newBackend.fileSystem,
            initialDirectory: newBackend.rootDirectory
        )

        fileBrowser.navigationRoot = activeProject == nil ? nil : rootDirectory
        terminalGeneration &+= 1
        terminalHost = nil
    }
}
