import Foundation
@testable import TypeNBash

@main
struct AppRouterIntegrationChecks {
    @MainActor static func main() async throws {
        let domain = "test.TypeNBash.Router.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        func makeRouter() -> AppRouter {
            AppRouter(session: WindowSession(localRoot: root),
                      profiles: SSHProfileStore(defaults: defaults),
                      store: ProjectStore(defaults: defaults))
        }

        let local = makeRouter()
        precondition(local.route == .entry)
        precondition(local.startupLocation == .local)
        local.openHome()
        precondition(local.route == .workspace && local.session.location == .local)
        local.close()

        let emptySSH = makeRouter()
        emptySSH.startupLocation = .ssh
        emptySSH.newProject()
        precondition(emptySSH.route == .sshSetup && emptySSH.startupMode == .projectNew,
                     "SSH project creation without saved hosts starts connection setup")
        emptySSH.setupCompleted()
        precondition(emptySSH.route == .projectSetup, "Connecting for a new project continues to project setup")
        emptySSH.cancelSetup()
        precondition(emptySSH.route == .entry && emptySSH.startupLocation == .ssh)
        emptySSH.openHome()
        precondition(emptySSH.route == .sshSetup && emptySSH.startupMode == .ssh)
        emptySSH.cancelSetup()
        emptySSH.close()

        for mode in [AppStartupModes.projectNew, .projectOpen] {
            let router = makeRouter()
            router.launch(mode)
            precondition(router.route == .projectSetup)
            router.launch(.free)
            precondition(router.route == .projectSetup, "Setup cannot be bypassed while presented")
            router.cancelSetup()
            precondition(router.route == .entry, "Cancellation must retain welcome screen")
            router.launch(mode)
            router.setupCompleted()
            precondition(router.route == .workspace)
            router.close()
        }

        let ssh = makeRouter()
        ssh.startupMode = .ssh
        ssh.newSSHConnection()
        precondition(ssh.route == .sshSetup)
        precondition(ssh.selectedSSHProfile == nil)
        ssh.cancelSetup()
        precondition(ssh.route == .entry && ssh.startupMode == .ssh)
        let profile = SSHConnectionProfile(name: "Fixture", host: "fixture.invalid")
        ssh.profiles.save(profile, password: nil)
        let localRecent = Project(name: "Local Recent", directoryPath: root.appendingPathComponent("recent").path)
        let remoteRecent = Project(name: "Remote Recent", directoryPath: root.appendingPathComponent("recent").path, sshProfileID: profile.id)
        ssh.projects.store.save(localRecent)
        ssh.projects.store.save(remoteRecent)
        ssh.startupLocation = .local
        precondition(ssh.recentProjects.map(\.id) == [localRecent.id])
        ssh.selectedProjectID = localRecent.id
        ssh.startupLocation = .ssh
        precondition(ssh.selectedProjectID == nil && ssh.recentProjects.map(\.id) == [remoteRecent.id],
                     "Tabs filter projects by host type and clear stale selection")
        ssh.openProject(localRecent)
        precondition(ssh.route == .entry && !ssh.projects.isBusy, "A hidden project cannot launch from the other tab")
        ssh.newProject()
        precondition(ssh.route == .projectSetup && ssh.selectedSSHProfile?.id == profile.id,
                     "SSH New Project preselects a saved host")
        ssh.cancelSetup()
        ssh.openHome()
        precondition(ssh.route == .sshSetup && ssh.selectedSSHProfile?.id == profile.id,
                     "SSH Open Home offers a saved host")
        ssh.cancelSetup()
        ssh.selectedSSHProfileID = profile.id
        ssh.launch(.ssh)
        precondition(ssh.route == .sshSetup && ssh.selectedSSHProfile?.id == profile.id)
        ssh.cancelSetup()
        ssh.newSSHConnection()
        precondition(ssh.selectedSSHProfileID == nil)
        ssh.setupCompleted()
        precondition(ssh.route == .workspace)
        ssh.close()

        let router = makeRouter()
        let project = Project(name: "Fixture", directoryPath: root.path)
        router.projects.store.save(project)
        router.openProject(project)
        await finish(router)
        precondition(router.route == .workspace)
        precondition(router.session.activeProject?.id == project.id)
        precondition(router.session.rootDirectory.standardizedFileURL == root.standardizedFileURL)
        router.close()

        let failed = makeRouter()
        let missing = Project(name: "Missing", directoryPath: root.appendingPathComponent("missing").path)
        failed.projects.store.save(missing)
        failed.selectedProjectID = missing.id
        failed.launch(.projectOpen)
        await finish(failed)
        precondition(failed.route == .entry && failed.projects.error != nil)
        precondition(failed.session.activeProject == nil)
        failed.launch(.free)
        precondition(failed.route == .workspace)
        failed.close()

        let cancelled = makeRouter()
        cancelled.selectedProjectID = project.id
        cancelled.launch(.projectOpen)
        cancelled.projects.cancel()
        try? await Task.sleep(for: .milliseconds(100))
        precondition(cancelled.route == .entry && cancelled.session.activeProject == nil)
        cancelled.close()
        let windows = WorkspaceWindows()
        let first = makeRouter()
        first.launch(.free)
        let firstGeneration = first.session.terminalGeneration
        let firstID = windows.insert(first)
        let second = makeRouter()
        second.launch(.free)
        let secondGeneration = second.session.terminalGeneration
        let secondID = windows.insert(second)
        precondition(firstID != secondID && windows.sessions.count == 2)
        precondition(windows.sessions[firstID] === first)
        precondition(first.session.terminalGeneration == firstGeneration, "Handoff must retain the prepared session")
        windows.close(firstID)
        precondition(windows.sessions[firstID] == nil)
        precondition(first.session.terminalGeneration > firstGeneration)
        precondition(second.session.terminalGeneration == secondGeneration, "Closing one window must preserve other sessions")
        windows.close(secondID)
        precondition(windows.sessions.isEmpty)
        print("App router checks passed: local launch, setup cancellation/completion, saved project handoff, failed-open retention, cancelled-open retention, independent window ownership.")
    }

    @MainActor static func finish(_ router: AppRouter) async {
        for _ in 0..<200 {
            if !router.projects.isBusy { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Project open timed out")
    }
}
