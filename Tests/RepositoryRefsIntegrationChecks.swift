import Foundation
@testable import TypeNBash

/// The Repositories tab against temporary repositories: listing refs, then the
/// context menu's switch, new branch and merge through the production service.
@main
struct RepositoryRefsIntegrationChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("centcom-refs-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let service = SourceControlService()
        func write(_ text: String, to name: String) throws {
            try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        func read(_ name: String) throws -> String {
            try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
        }
        func commit(_ name: String, _ text: String) throws {
            try write(text, to: name)
            try git(["add", name], at: root)
            try git(["commit", "-q", "-m", "\(name): \(text)"], at: root)
        }
        func head() throws -> String { try git(["rev-parse", "HEAD"], at: root) }
        func parents() throws -> Int {
            try git(["rev-list", "--parents", "-n", "1", "HEAD"], at: root).split(separator: " ").count - 1
        }
        func mergeHeadExists() -> Bool {
            FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/MERGE_HEAD").path)
        }
        func perform(_ action: GitRefAction) async throws -> GitMergeOutcome? {
            try await service.perform(action, in: root, defaultIdentity: nil)
        }
        func check(_ condition: Bool, _ message: String = "Check failed", line: UInt = #line) { precondition(condition, message, line: line) }
        let main = GitBranchRef(branch: "main")

        FileHandle.standardError.write(Data("Checking ref listing\n".utf8))
        try git(["init", "-q", "-b", "main"], at: root)
        try git(["config", "user.name", "Fixture"], at: root)
        try git(["config", "user.email", "fixture@example.invalid"], at: root)
        try commit("a.txt", "base\n")
        try git(["tag", "v1.0.0"], at: root)
        try git(["tag", "-a", "v1.0.0-beta", "-m", "Annotated"], at: root)
        try git(["branch", "claude/feature"], at: root)
        // Beside the repository, not in it, so it never shows as untracked.
        let remote = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-remote.git")
        defer { try? FileManager.default.removeItem(at: remote) }
        try git(["init", "-q", "--bare", remote.path], at: root)
        try git(["remote", "add", "origin", remote.path], at: root)
        try git(["push", "-q", "origin", "main", "main:remote-only"], at: root)
        try git(["fetch", "-q", "origin"], at: root)
        try git(["remote", "set-head", "origin", "main"], at: root)
        try write("stashed\n", to: "a.txt")
        try git(["stash", "push", "-q", "-m", "WIP fixture"], at: root)
        var refs = try await service.refs(in: root)
        precondition(refs.current == "main")
        precondition(refs.branches == ["claude/feature", "main"])
        precondition(refs.tags == ["v1.0.0", "v1.0.0-beta"])
        precondition(refs.stashes.count == 1 && refs.stashes[0].contains("WIP fixture"))
        precondition(refs.remotes.map(\.name) == ["origin"])
        precondition(refs.remotes[0].branches == ["main", "remote-only"], "origin/HEAD should be hidden")
        let outline = GitRefNode.outline(refs.branches, kind: .branch, idPrefix: "refs/heads/", current: refs.current)
        precondition(outline.map(\.title) == ["claude", "main"] && outline[0].kind == .folder)
        precondition(outline[0].children[0].ref == GitBranchRef(branch: "claude/feature"))
        precondition(outline[1].isCurrent)

        FileHandle.standardError.write(Data("Checking switch and recents\n".utf8))
        _ = try await perform(.switchTo(GitBranchRef(branch: "claude/feature")))
        try commit("a.txt", "feature\n")
        refs = try await service.refs(in: root)
        precondition(refs.current == "claude/feature")
        precondition(refs.recents == ["claude/feature", "main"])

        FileHandle.standardError.write(Data("Checking a switch never discards uncommitted work\n".utf8))
        try write("dirty\n", to: "a.txt")
        do {
            _ = try await perform(.switchTo(main))
            fatalError("Switch overwrote an uncommitted change")
        } catch {
            try check(read("a.txt") == "dirty\n")
            try await check(service.refs(in: root).current == "claude/feature")
        }
        try git(["checkout", "-q", "--", "a.txt"], at: root)

        FileHandle.standardError.write(Data("Checking fast-forward\n".utf8))
        let featureHead = try head()
        _ = try await perform(.switchTo(main))
        guard case .fastForward = try await perform(.merge(GitBranchRef(branch: "claude/feature"))) else {
            fatalError("Expected a fast-forward")
        }
        try check(head() == featureHead && read("a.txt") == "feature\n")
        guard case .upToDate = try await perform(.merge(GitBranchRef(branch: "claude/feature"))) else {
            fatalError("Expected up to date")
        }

        FileHandle.standardError.write(Data("Checking new branch and merge commit\n".utf8))
        _ = try await perform(.newBranch("side", from: main))
        try await check(service.refs(in: root).current == "side")
        try commit("b.txt", "side\n")
        _ = try await perform(.switchTo(main))
        try commit("c.txt", "main\n")
        guard case .merged = try await perform(.merge(GitBranchRef(branch: "side"))) else {
            fatalError("Expected a merge commit")
        }
        try check(parents() == 2 && read("b.txt") == "side\n" && !mergeHeadExists())
        try check(git(["log", "-1", "--format=%s"], at: root).hasPrefix("Merge branch 'side'"))
        let status = try git(["status", "--porcelain"], at: root)
        check(status.isEmpty, "Unclean after merge: \(status)")

        FileHandle.standardError.write(Data("Checking staged changes block a merge\n".utf8))
        try git(["branch", "later"], at: root)
        try write("staged\n", to: "c.txt")
        try git(["add", "c.txt"], at: root)
        let beforeStaged = try head()
        do {
            _ = try await perform(.merge(GitBranchRef(branch: "later")))
            fatalError("Merged with staged changes")
        } catch GitRefActionError.stagedChanges {
            try check(head() == beforeStaged && read("c.txt") == "staged\n")
        }
        try git(["reset", "-q", "--hard"], at: root)

        FileHandle.standardError.write(Data("Checking switching to a remote branch\n".utf8))
        _ = try await perform(.switchTo(GitBranchRef(branch: "remote-only", remote: "origin")))
        refs = try await service.refs(in: root)
        precondition(refs.current == "remote-only" && refs.branches.contains("remote-only"))
        try check(git(["rev-parse", "--abbrev-ref", "remote-only@{upstream}"], at: root) == "origin/remote-only\n")
        _ = try await perform(.switchTo(main))

        FileHandle.standardError.write(Data("Checking conflicts, then finishing with the app's commit\n".utf8))
        _ = try await perform(.newBranch("conflict", from: main))
        try commit("a.txt", "theirs\n")
        _ = try await perform(.switchTo(main))
        try commit("a.txt", "ours\n")
        let beforeConflict = try head()
        guard case .conflicts(1) = try await perform(.merge(GitBranchRef(branch: "conflict"))) else {
            fatalError("Expected one conflicted file")
        }
        try check(mergeHeadExists() && head() == beforeConflict)
        try check(read("a.txt").contains("<<<<<<<"))
        do {
            _ = try await perform(.merge(GitBranchRef(branch: "side")))
            fatalError("Started a second merge")
        } catch GitRefActionError.operationInProgress {}
        try write("resolved\n", to: "a.txt")
        _ = try await service.perform(.stage("a.txt"), in: root)
        _ = try await service.perform(.commit("Merge conflict"), in: root)
        try check(parents() == 2 && !mergeHeadExists(), "The merge state should be cleared")
        try write("after\n", to: "d.txt")
        _ = try await service.perform(.stage("d.txt"), in: root)
        _ = try await service.perform(.commit("After merge"), in: root)
        try check(parents() == 1, "A commit after a finished merge must not be a merge")

        FileHandle.standardError.write(Data("Checking invalid branch names\n".utf8))
        do {
            _ = try await perform(.newBranch("-x", from: main))
            fatalError("Accepted an option-like branch name")
        } catch GitRefActionError.invalidName {}

        print("Repository refs checks passed")
    }

    @discardableResult static func git(_ arguments: [String], at root: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = root
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        precondition(process.terminationStatus == 0, "Fixture git command failed: \(arguments.joined(separator: " "))")
        return String(decoding: data, as: UTF8.self)
    }
}
