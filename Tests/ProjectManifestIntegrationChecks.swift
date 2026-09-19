import Foundation
@testable import TypeNBash

@main
struct ProjectManifestIntegrationChecks {
    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("project-definition-\(UUID())")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let defaultsName = "ProjectDefinitions-\(UUID())"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let store = ProjectStore(defaults: defaults)
        let session = WindowSession(localRoot: root)
        defer { session.close() }
        let picker = ProjectPickerModel(session: session, profiles: SSHProfileStore(defaults: defaults), store: store)
        picker.setupMode = .newFolder
        picker.directoryPath = root.path
        picker.name = "Analysis café"
        picker.outputDirectory = "results"
        var completed = false
        picker.saveAndOpen { completed = true }
        await wait(picker)
        let projectRoot = root.appendingPathComponent("Analysis café")
        let config = projectRoot.appendingPathComponent(ProjectManifest.filename)
        check(completed && picker.error == nil, "Creates and opens a named project subdirectory")
        check(session.rootDirectory == projectRoot && session.activeProject?.manifest?.outputDirectory == "results",
              "The session owns the created root and output settings")
        check(fm.fileExists(atPath: config.path), "Project definition is stored with the files")
        check(!fm.fileExists(atPath: projectRoot.appendingPathComponent("results").path), "Output folder creation is lazy")
        let output = try await session.prepareProjectOutputDirectory()
        check(output == projectRoot.appendingPathComponent("results").resolvingSymlinksInPath(), "Exports resolve inside the project")
        let again = try await session.prepareProjectOutputDirectory()
        check(again == output, "Repeated output preparation reuses the directory")
        let original = try Data(contentsOf: config)
        picker.saveAndOpen {}
        await wait(picker)
        check(picker.error != nil && (try? Data(contentsOf: config)) == original,
              "Creating a project never replaces an existing folder or definition")

        let plain = root.appendingPathComponent("plain")
        try fm.createDirectory(at: plain, withIntermediateDirectories: false)
        try Data("keep".utf8).write(to: plain.appendingPathComponent("notes.txt"))
        picker.setupMode = .openFolder
        picker.directoryPath = plain.path
        picker.name = ""
        picker.saveAndOpen {}
        await wait(picker)
        check(picker.error == nil && session.activeProject?.manifest == nil && !fm.fileExists(atPath: plain.appendingPathComponent(ProjectManifest.filename).path),
              "Opening an ordinary directory does not write project metadata")
        picker.setupMode = .initializeFolder
        picker.saveAndOpen {}
        await wait(picker)
        check(picker.error == nil && session.activeProject?.manifest?.name == "plain",
              "Existing folders can be initialized without a custom name")
        check(try String(contentsOf: plain.appendingPathComponent("notes.txt"), encoding: .utf8) == "keep",
              "Initialization preserves existing files")
        picker.saveAndOpen {}
        await wait(picker)
        check(picker.error != nil, "Reinitialization refuses to overwrite the definition")

        let relocated = root.appendingPathComponent("relocated")
        try fm.copyItem(at: projectRoot, to: relocated)
        picker.setupMode = .openFolder
        picker.directoryPath = relocated.appendingPathComponent(ProjectManifest.filename).path
        picker.saveAndOpen {}
        await wait(picker)
        check(picker.error == nil && session.rootDirectory.path == relocated.path && session.activeProject?.name == "Analysis café",
              "Opening a moved project definition uses its containing directory and saved name")
        check(store.project(atDirectory: projectRoot.path)?.id != store.project(atDirectory: relocated.path)?.id,
              "Copied projects remain distinct recent entries")

        let broken = root.appendingPathComponent("broken")
        try fm.createDirectory(at: broken, withIntermediateDirectories: false)
        let badConfig = broken.appendingPathComponent(ProjectManifest.filename)
        for data in [Data("not json".utf8), Data(#"{"version":2,"name":"Future","outputDirectory":"output"}"#.utf8),
                     Data(#"{"version":1,"name":"Escape","outputDirectory":"../outside"}"#.utf8)] {
            try data.write(to: badConfig)
            picker.directoryPath = broken.path
            picker.saveAndOpen {}
            await wait(picker)
            check(picker.error != nil && session.rootDirectory.path == relocated.path,
                  "Malformed, unsupported and escaping definitions leave the active workspace unchanged")
        }
        let outside = root.appendingPathComponent("outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: false)
        try fm.removeItem(at: relocated.appendingPathComponent("results"))
        try fm.createSymbolicLink(at: relocated.appendingPathComponent("results"), withDestinationURL: outside)
        do {
            _ = try await session.prepareProjectOutputDirectory()
            fatalError("Export accepted an output symlink outside the project")
        } catch { print("PASS: Output symlinks cannot escape the project") }
        let fs = LocalWorkspaceFileSystem()
        do {
            try await fs.createFile(Data("replacement".utf8), at: config)
            fatalError("Exclusive creation replaced existing metadata")
        } catch { check(try Data(contentsOf: config) == original, "Exclusive creation protects existing definitions") }
        check(ProjectStore(defaults: defaults).projects.count == store.projects.count,
              "Recent projects with definitions survive persistence")
        print("Project definition integration checks passed")
    }

    @MainActor static func wait(_ model: ProjectPickerModel) async {
        while model.isBusy { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
}
