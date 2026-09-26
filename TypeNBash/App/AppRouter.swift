import Foundation
import Observation

enum AppStartupModes: String, CaseIterable, Identifiable, Sendable, Hashable {
    case projectNew = "Project Space"
    case projectOpen = "Open Project"
    case ssh = "SSH"
    case free = "Home"

    var id: Self { self }
}

/// One router per window. Setup and the canvas share the same workspace session.
@MainActor
@Observable
final class AppRouter {
    enum StartupLocation: String, CaseIterable, Identifiable {
        case local = "Local", ssh = "SSH"
        var id: Self { self }
    }
    enum Route: String, Hashable, Decodable { case entry, sshSetup, projectSetup, workspace }
    private(set) var route: Route = .entry
    var startupMode: AppStartupModes = .free
    var startupLocation: StartupLocation = .local {
        didSet {
            guard startupLocation != oldValue else { return }
            selectedProjectID = nil
            projects.locationChanged()
        }
    }
    var selectedSSHProfileID: UUID?
    var selectedProjectID: Project.ID?
    let session: WindowSession
    let profiles: SSHProfileStore
    let projects: ProjectPickerModel

    init(session: WindowSession? = nil, profiles: SSHProfileStore? = nil, store: ProjectStore? = nil) {
        let session = session ?? WindowSession()
        let profiles = profiles ?? .shared
        self.session = session
        self.profiles = profiles
        projects = ProjectPickerModel(session: session, profiles: profiles, store: store)
    }

    func launch(_ mode: AppStartupModes) {
        guard route == .entry, !projects.isBusy else { return }
        startupMode = mode
        switch mode {
        case .free:
            if session.location != .local { session.disconnectToLocal() }
            route = .workspace
        case .ssh:
            startupLocation = .ssh
            route = .sshSetup
        case .projectNew:
            newProject()
        case .projectOpen:
            guard let project = projects.store.projects.first(where: { $0.id == selectedProjectID }) else {
                newProject()
                return
            }
            projects.openSaved(project) { [weak self] in self?.route = .workspace }
        }
    }

    var selectedSSHProfile: SSHConnectionProfile? {
        profiles.profiles.first { $0.id == selectedSSHProfileID }
    }

    var recentProjects: [Project] {
        projects.store.recents.filter { $0.isLocal == (startupLocation == .local) }
    }

    func openProject(_ project: Project) {
        guard route == .entry, !projects.isBusy, recentProjects.contains(where: { $0.id == project.id }) else { return }
        selectedProjectID = project.id
        launch(.projectOpen)
    }

    func openHome() {
        guard route == .entry, !projects.isBusy else { return }
        if startupLocation == .ssh {
            selectedSSHProfileID = selectedSSHProfile?.id ?? profiles.profiles.first?.id
            launch(.ssh)
        } else {
            launch(.free)
        }
    }

    func newProject() {
        guard route == .entry, !projects.isBusy else { return }
        selectedProjectID = nil
        startupMode = .projectNew
        if startupLocation == .ssh {
            selectedSSHProfileID = selectedSSHProfile?.id ?? profiles.profiles.first?.id
            route = selectedSSHProfile == nil ? .sshSetup : .projectSetup
        } else {
            selectedSSHProfileID = nil
            route = .projectSetup
        }
    }
    func newSSHConnection() {
        guard route == .entry, !projects.isBusy else { return }
        selectedSSHProfileID = nil
        startupLocation = .ssh
        startupMode = .ssh
        route = .sshSetup
    }

    func cancelSetup() {
        guard route == .sshSetup || route == .projectSetup else { return }
        if session.location != .local { session.disconnectToLocal() }
        route = .entry
    }

    func setupCompleted() {
        guard route == .sshSetup || route == .projectSetup else { return }
        if route == .sshSetup, startupMode == .projectNew {
            if case .ssh(let profile) = session.location { selectedSSHProfileID = profile.id }
            route = .projectSetup
            return
        }
        route = .workspace
    }

    func close() {
        projects.cancel()
        session.close()
    }
}
