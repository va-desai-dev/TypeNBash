import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct RuntimeIntegrationChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count > 1 {
            let root = CommandLine.arguments[1]
            let localRC = TerminalShellIntegration.makeZDOTDIR()!
            let fixture: [String: String] = [
                "remote": TerminalShellIntegration.remoteLaunchCommand(workingDirectory: root),
                "localRC": localRC.path
            ]
            print(String(decoding: try JSONEncoder().encode(fixture), as: UTF8.self))
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("centcom-runtime-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let child = root.appendingPathComponent("a #?% ' café")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)

        let session = WindowSession(localRoot: root)
        let generation = session.terminalGeneration
        session.terminalReported(host: "host.example", directory: child, generation: generation)
        check(session.fileBrowser.directory.path == child.path, "Directory reports follow the active filesystem")
        session.fileBrowser.newFile()
        session.fileBrowser.updatePreviewText("keep this draft")
        session.terminalReported(host: "HOST.EXAMPLE.", directory: child, generation: generation)
        check(session.fileBrowser.hasUnsavedChanges && session.fileBrowser.isUntitled,
              "Repeated prompts preserve unsaved preview state")
        session.terminalReported(host: "host.other", directory: root, generation: generation)
        check(session.fileBrowser.directory.path == child.path, "Different hosts with the same first label cannot switch workspaces")
        session.disconnectToLocal()
        check(session.rootDirectory.path == child.path, "Disconnect restores the last local terminal directory")
        let replacement = session.terminalGeneration
        session.terminalReported(host: "old", directory: root, generation: generation)
        session.handleTerminalExit(generation: generation)
        check(session.terminalGeneration == replacement && session.fileBrowser.directory.path == child.path,
              "Stale directory and exit callbacks cannot mutate the replacement session")
        await session.connect(to: SSHConnectionProfile(name: "invalid", host: ""))
        check(session.location == .local && session.terminalGeneration == replacement,
              "Failed profile connection retains the active terminal and filesystem")
        session.handleTerminalExit(generation: replacement)
        check(session.state == .local && session.terminalGeneration == replacement + 1,
              "Terminal exit returns to a consistent local state")
        session.close()

        let defaultsName = "ProjectChecks-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let projects = ProjectStore(defaults: defaults)
        let profileStore = SSHProfileStore(defaults: defaults)
        let remoteID = UUID()
        let localProject = projects.makeProject(directoryPath: child.path)
        let remoteProject = projects.makeProject(directoryPath: child.path, sshProfileID: remoteID)
        projects.save(localProject)
        projects.save(remoteProject)
        check(projects.projects.count == 2 && projects.project(atDirectory: child.path)?.id == localProject.id,
              "Identical paths on this Mac and SSH remain separate projects")
        check(projects.project(atDirectory: child.path + "/", sshProfileID: remoteID)?.id == remoteProject.id,
              "Remote project lookup ignores a trailing slash")
        check(ProjectStore(defaults: defaults).projects.contains(remoteProject),
              "Remote host identity survives project persistence")
        do {
            _ = try projects.resolve(remoteProject, using: profileStore)
            fatalError("Missing SSH profile should fail resolution")
        } catch ProjectError.missingConnection { }
        let projectSession = WindowSession(localRoot: root)
        await projectSession.open(localProject, at: .local(child))
        check(!projectSession.fileBrowser.canGoUp, "Up is disabled at the project root")
        projectSession.fileBrowser.goUp()
        projectSession.fileBrowser.navigate(to: root)
        check(projectSession.fileBrowser.directory == child.standardizedFileURL,
              "Browser actions cannot leave the project root")
        let nested = child.appendingPathComponent("nested")
        projectSession.fileBrowser.navigate(to: nested)
        check(projectSession.fileBrowser.canGoUp && projectSession.fileBrowser.canGoBack,
              "Navigation stays enabled within a project")
        projectSession.fileBrowser.goBack()
        check(!projectSession.fileBrowser.canGoUp && projectSession.fileBrowser.canGoForward,
              "Returning to the root preserves forward navigation")
        projectSession.fileBrowser.goForward()
        projectSession.fileBrowser.goUp()
        projectSession.fileBrowser.navigate(to: URL(fileURLWithPath: child.path + "-sibling"))
        check(projectSession.fileBrowser.directory == child.standardizedFileURL,
              "A shared path prefix does not admit sibling directories")
        projectSession.terminalReported(host: nil, directory: root, generation: projectSession.terminalGeneration)
        check(projectSession.fileBrowser.directory.path == child.path, "A terminal cannot drag a project outside its root")
        projectSession.fileBrowser.newFile()
        projectSession.fileBrowser.updatePreviewText("project draft stays put")
        projectSession.terminalReported(host: nil, directory: nested, generation: projectSession.terminalGeneration)
        check(projectSession.fileBrowser.directory.standardizedFileURL == child.standardizedFileURL,
              "Project console directory changes do not navigate the editor")
        check(projectSession.fileBrowser.isUntitled && projectSession.fileBrowser.hasUnsavedChanges,
              "Project console directory changes preserve unsaved drafts")
        if case .text(let draft) = projectSession.fileBrowser.preview {
            check(draft == "project draft stays put", "Project draft contents survive console navigation")
        } else {
            fatalError("Project console replaced the editor preview")
        }
        await projectSession.connect(to: SSHConnectionProfile(name: "invalid", host: ""))
        check(projectSession.activeProject?.id == localProject.id && projectSession.rootDirectory.path == child.path,
              "Failed SSH connection preserves the active project and its root")
        projectSession.handleTerminalExit(generation: projectSession.terminalGeneration)
        check(projectSession.activeProject?.id == localProject.id && projectSession.rootDirectory.path == child.path,
              "A shell restart retains the local project's root")
        check(!projectSession.fileBrowser.canGoUp, "Shell restart retains browser navigation guards")
        check(projectSession.fileBrowser.isUntitled && projectSession.fileBrowser.hasUnsavedChanges,
              "Restarting a project console preserves the editor draft")
        projectSession.closeProject()
        check(projectSession.fileBrowser.canGoUp, "Closing a project releases the browser boundary")
        projectSession.fileBrowser.goUp()
        check(projectSession.fileBrowser.directory == root.standardizedFileURL,
              "Unscoped browsing can navigate above the former root")
        projectSession.fileBrowser.navigationRoot = root
        projectSession.fileBrowser.navigate(to: child)
        projectSession.fileBrowser.navigationRoot = child
        check(!projectSession.fileBrowser.canGoBack, "Back cannot revisit history outside the current root")
        projectSession.fileBrowser.goBack()
        check(projectSession.fileBrowser.directory == child.standardizedFileURL,
              "Disabled Back also refuses programmatic navigation")
        projectSession.fileBrowser.navigationRoot = nil
        projectSession.disconnectToLocal(rootDirectory: root)
        check(projectSession.activeProject == nil, "Explicit workspace replacement clears the old project")
        let picker = ProjectPickerModel(session: projectSession, profiles: profileStore, store: projects)
        picker.directoryPath = root.appendingPathComponent("missing").path
        let before = picker.store.projects
        picker.saveAndOpen { fatalError("Missing directory must not open") }
        while picker.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        check(picker.error != nil && picker.store.projects == before && projectSession.rootDirectory.path == root.path,
              "Invalid project paths report errors without saving or replacing the workspace")
        picker.cancel()
        let hiddenFolder = root.appendingPathComponent(".hidden-folder")
        try FileManager.default.createDirectory(at: hiddenFolder, withIntermediateDirectories: false)
        try Data("file".utf8).write(to: root.appendingPathComponent("ordinary-file"))
        let linkedFolder = root.appendingPathComponent("linked-folder")
        try FileManager.default.createSymbolicLink(at: linkedFolder, withDestinationURL: child)
        picker.directoryPath = root.path
        picker.chooseFolder()
        while picker.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        check(picker.isBrowsing && picker.error == nil && picker.folders.contains(where: { $0.url.lastPathComponent == child.lastPathComponent }),
              "Local Choose Folder opens the in-app picker with the requested directory")
        check(!picker.folders.contains(where: { $0.url.lastPathComponent == "ordinary-file" || $0.url.lastPathComponent == ".hidden-folder" }),
              "Local picker lists directories and hides hidden folders by default")
        check(picker.folders.contains(where: { $0.url.lastPathComponent == "linked-folder" }),
              "Local picker includes symlinked directories in its folder list")
        picker.showsHiddenFiles = true
        picker.browse(path: root.path)
        while picker.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        check(picker.folders.contains(where: { $0.url.lastPathComponent == ".hidden-folder" }),
              "Local picker can reveal hidden folders")
        picker.browse(path: linkedFolder.path)
        while picker.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        check(picker.browsedDirectory?.path == child.resolvingSymlinksInPath().path,
              "Local picker resolves directory symlinks")
        picker.useBrowsedFolder()
        check(!picker.isBrowsing && picker.directoryPath == child.resolvingSymlinksInPath().path && projectSession.rootDirectory.path == root.path,
              "Choosing a local folder updates the selection without switching the workspace")
        picker.browse(path: root.appendingPathComponent("missing").path)
        while picker.isBusy { try await Task.sleep(for: .milliseconds(10)) }
        check(picker.error != nil, "Invalid local picker paths surface an error")
        picker.cancel()
        projectSession.close()

        let encoded = child.path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "#?%")))!
        let report = TerminalHostView.Coordinator.parseReport("file://remote.example" + encoded)
        check(report?.directory.path == child.path && report?.host == "remote.example",
              "OSC 7 decodes reserved characters and Unicode without losing authority")
        check(TerminalHostView.Coordinator.parseReport("not/a/path") == nil,
              "Relative directory reports are ignored")
        let monitor = SystemMonitor()
        var remote = LinuxTelemetrySnapshot()
        remote.totalMemoryGB = 1024
        remote.networkReceivedBytes = 9_000_000
        remote.networkTransmittedBytes = 9_000_000
        monitor.applyLinuxTelemetry(remote)
        check(monitor.totalMemoryGB == 1024, "Remote telemetry owns the memory total")
        remote.networkReceivedBytes = 1
        remote.networkTransmittedBytes = 1
        monitor.applyLinuxTelemetry(remote)
        check(monitor.downloadSpeedString == "0 B/s" && monitor.uploadSpeedString == "0 B/s",
              "Reset network counters cannot underflow into enormous transfer rates")
        monitor.useLocalTelemetry()
        check(monitor.totalMemoryGB == Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824.0,
              "Returning local restores this Mac's physical memory total")
        monitor.useRemoteTelemetry(reset: true)
        check(monitor.history.isEmpty && monitor.downloadSpeedString == "0 KB/s",
              "Switching remote workspaces resets telemetry baselines")
        check(TelemetryGeometry.segmentWidth(value: 2, total: 8, availableWidth: 240) == 60,
              "Memory bars preserve valid segment proportions")
        for invalid in [-1.0, .nan, .infinity, -.infinity] {
            check(TelemetryGeometry.segmentWidth(value: invalid, total: 8, availableWidth: 240) == 0,
                  "Invalid memory values cannot create invalid frame widths: \(invalid)")
        }
        for width: CGFloat in [-1, .nan, .infinity] {
            check(TelemetryGeometry.segmentWidth(value: 2, total: 8, availableWidth: width) == 0,
                  "Transient invalid layout proposals produce a zero-width segment")
        }
        check(TelemetryGeometry.segmentWidth(value: 2, total: 0, availableWidth: 240) == 0 &&
              TelemetryGeometry.segmentWidth(value: 2, total: .infinity, availableWidth: 240) == 0,
              "Missing or overflowing memory totals cannot create invalid frames")
        weak var releasedMonitor: SystemMonitor?
        do {
            let temporaryMonitor = SystemMonitor()
            releasedMonitor = temporaryMonitor
            // Exercise the active CPU sampler before monitor teardown.
            try await Task.sleep(for: .milliseconds(1200))
        }
        for _ in 0..<20 where releasedMonitor != nil {
            try await Task.sleep(for: .milliseconds(50))
        }
        check(releasedMonitor == nil, "Telemetry timers, tasks and network callbacks release their monitor")
        print("Runtime state checks passed")
    }

    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else { fatalError(message) }
        print("PASS: \(message)")
    }
}
