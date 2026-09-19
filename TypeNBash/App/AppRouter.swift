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
    enum Route: String, Hashable, Decodable { case entry, sshSetup, projectSetup, workspace }
    private(set) var route: Route = .entry
    var startupMode: AppStartupModes = .free
    var selectedSSHProfileID: UUID?
    var selectedProjectID: Project.ID?
    let session: WindowSession
    let profiles: SSHProfileStore
    let projects: ProjectPickerModel

    init(session: WindowSession? = nil, profiles: SSHProfileStore? = nil, store: ProjectStore? = nil) {
        let session = session ?? WindowSession()
        let profiles = profiles ?? SSHProfileStore()
        self.session = session
        self.profiles = profiles
        projects = ProjectPickerModel(session: session, profiles: profiles, store: store)
    }

    func launch(_ mode: AppStartupModes) {
        guard route == .entry, !projects.isBusy else { return }
        switch mode {
        case .free:
            route = .workspace
        case .ssh:
            route = .sshSetup
        case .projectNew:
            route = .projectSetup
        case .projectOpen:
            guard let project = projects.store.projects.first(where: { $0.id == selectedProjectID }) else {
                route = .projectSetup
                return
            }
            projects.openSaved(project) { [weak self] in self?.route = .workspace }
        }
    }

    var selectedSSHProfile: SSHConnectionProfile? {
        profiles.profiles.first { $0.id == selectedSSHProfileID }
    }

    func newProject() {
        guard route == .entry else { return }
        selectedProjectID = nil
        startupMode = .projectNew
        route = .projectSetup
    }
    func newSSHConnection() {
        guard route == .entry, !projects.isBusy else { return }
        selectedSSHProfileID = nil
        startupMode = .ssh
        route = .sshSetup
    }

    func cancelSetup() {
        guard route == .sshSetup || route == .projectSetup else { return }
        route = .entry
    }

    func setupCompleted() {
        guard route == .sshSetup || route == .projectSetup else { return }
        route = .workspace
    }

    func close() {
        projects.cancel()
        session.close()
    }
}
