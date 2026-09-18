import Foundation
@testable import TypeNBash

@main
struct SourceControlIntegrationChecks {
    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("centcom-git-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SourceControlService()
        FileHandle.standardError.write(Data("Checking repository discovery\n".utf8))
        do {
            _ = try await service.perform(.refresh, in: root)
            fatalError("Non-repository unexpectedly opened")
        } catch {
            precondition(!FileManager.default.fileExists(atPath: root.appendingPathComponent(".git").path))
        }
        FileHandle.standardError.write(Data("Checking initial commit\n".utf8))
        try git(["init", "-b", "main"], at: root)
        try git(["config", "user.name", "Fixture"], at: root)
        try git(["config", "user.email", "fixture@example.invalid"], at: root)
        let nested = root.appendingPathComponent("nested # café")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let path = "nested # café/file [1].txt"
        let file = root.appendingPathComponent(path)
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        var state = try await service.perform(.refresh, in: nested)
        precondition(state.unborn && state.changes.count == 1 && state.changes[0].path == path)
        state = try await service.perform(.stage(path), in: root)
        precondition(state.changes[0].staged && !state.changes[0].unstaged)
        state = try await service.perform(.commit("Initial fixture"), in: root)
        precondition(!state.unborn && state.branch == "main" && state.changes.isEmpty)
        try "second\n".write(to: file, atomically: true, encoding: .utf8)
        _ = try await service.perform(.stage(path), in: root)
        try "third\n".write(to: file, atomically: true, encoding: .utf8)
        state = try await service.perform(.refresh, in: root)
        precondition(state.changes[0].staged && state.changes[0].unstaged)
        state = try await service.perform(.unstage(path), in: root)
        precondition(!state.changes[0].staged && state.changes[0].unstaged)
        let contents = try String(contentsOf: file, encoding: .utf8)
        precondition(contents == "third\n")
        try FileManager.default.removeItem(at: file)
        state = try await service.perform(.stage(path), in: root)
        precondition(state.changes[0].staged && !state.changes[0].unstaged)
        state = try await service.perform(.commit("Delete fixture"), in: root)
        precondition(state.changes.isEmpty)
        let remote = root.appendingPathComponent("remote.git")
        try git(["init", "--bare", remote.path], at: root)
        try git(["remote", "add", "origin", remote.path], at: root)
        try git(["push", "origin", "main"], at: root)
        state = try await service.perform(.fetch("origin"), in: root)
        precondition(state.remotes == ["origin"])
        let worktree = root.appendingPathComponent("linked")
        try git(["worktree", "add", "-b", "linked", worktree.path], at: root)
        state = try await service.perform(.refresh, in: worktree)
        precondition(state.branch == "linked")
        print("Source control checks passed: discovery, no implicit initialization, initial commit, literal paths, partial staging, unstage preserves content, deletion, local remote fetch, linked worktree.")
    }

    static func git(_ arguments: [String], at root: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Fixture git command failed: \(arguments.first ?? "")")
    }
}
