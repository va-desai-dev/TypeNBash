import Foundation
@testable import TypeNBash

@main
struct SourceControlIntegrationChecks {
    @MainActor static func main() async throws {
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
        try git(["config", "remote.origin.push", "+refs/heads/*:refs/heads/*"], at: root)
        try git(["branch", "unrelated"], at: root)
        _ = try await service.perform(.push("origin"), in: root)
        let remoteMain = remote.appendingPathComponent("refs/heads/main")
        precondition(FileManager.default.fileExists(atPath: remoteMain.path))
        precondition(!FileManager.default.fileExists(atPath: remote.appendingPathComponent("refs/heads/unrelated").path))
        state = try await service.perform(.fetch("origin"), in: root)
        precondition(state.remotes == ["origin"])
        let worktree = root.appendingPathComponent("linked")
        try git(["worktree", "add", "-b", "linked", worktree.path], at: root)
        state = try await service.perform(.refresh, in: worktree)
        precondition(state.branch == "linked")
        try git(["checkout", "--detach"], at: root)
        do {
            _ = try await service.perform(.push("origin"), in: root)
            fatalError("Detached HEAD push should fail")
        } catch { precondition(error is GitPushError) }
        try git(["checkout", "main"], at: root)
        let writer = root.appendingPathComponent("writer")
        try git(["clone", "-b", "main", remote.path, writer.path], at: root)
        try git(["config", "user.name", "Other fixture"], at: writer)
        try git(["config", "user.email", "other@example.invalid"], at: writer)
        try git(["commit", "--allow-empty", "-m", "Remote change"], at: writer)
        try git(["push", "origin", "main"], at: writer)
        let before = try String(contentsOf: remoteMain, encoding: .utf8)
        try git(["commit", "--allow-empty", "-m", "Local divergence"], at: root)
        do {
            _ = try await service.perform(.push("origin"), in: root)
            fatalError("Diverged push should fail")
        } catch { precondition(error is GitPushError) }
        let after = try String(contentsOf: remoteMain, encoding: .utf8)
        precondition(before == after, "Rejected push must leave the remote branch untouched")
        let suite = "centcom-git-identity-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SourceControlIdentitySettings(defaults: defaults)
        try await checkExistingRepository(at: root.appendingPathComponent("existing-repository"), settings: settings)
        try await checkAppIdentity(at: root, defaults: defaults)
        print("Push checks passed: publication, explicit branch only, detached HEAD refusal, non-fast-forward refusal without changing remote history.")
        print("Source control checks passed: discovery, no implicit initialization, initial commit, literal paths, partial staging, unstage preserves content, deletion, local remote fetch, linked worktree.")
    }

    @MainActor static func checkExistingRepository(at root: URL, settings: SourceControlIdentitySettings) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: root)
        try git(["config", "user.name", "Existing fixture"], at: root)
        try git(["config", "user.email", "existing@example.invalid"], at: root)
        try git(["config", "commit.gpgsign", "false"], at: root)
        let file = root.appendingPathComponent("tracked.txt")
        try "base\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "tracked.txt"], at: root)
        try git(["commit", "-m", "Created outside TypeNBash"], at: root)
        let parent = try git(["rev-parse", "HEAD"], at: root)
        try "staged\n".write(to: file, atomically: true, encoding: .utf8)
        let model = SourceControlModel(directory: root, identitySettings: settings)
        await model.run(.refresh)
        await model.run(.stage("tracked.txt"))
        try "unstaged\n".write(to: file, atomically: true, encoding: .utf8)
        model.commitMessage = "Keep my staged changes"
        precondition(model.canCommit)

        // A repo-local empty value overrides any developer machine identity.
        try git(["config", "user.name", ""], at: root)
        await model.run(.commit(model.commitMessage))
        precondition(model.errorMessage?.contains("commit name and email") == true,
                     "Missing identity must explain the repository-local remedy")
        precondition(model.commitMessage == "Keep my staged changes" && model.snapshot?.changes.first?.staged == true)
        precondition(model.needsIdentity && model.isEditingIdentity && !model.canCommit)
        precondition(model.identityDraft.email == "existing@example.invalid", "Keep any identity field that is already available")
        check(try git(["rev-parse", "HEAD"], at: root) == parent)

        model.identityDraft = .init(name: "  Repository Author  ", email: "  author@example.invalid  ")
        model.rememberIdentity = true
        await model.saveIdentity()
        precondition(settings.identity == .init(name: "Repository Author", email: "author@example.invalid"))
        precondition(model.errorMessage == nil && !model.needsIdentity && !model.isEditingIdentity && model.canCommit)
        precondition(model.commitMessage == "Keep my staged changes", "Saving identity must preserve the pending commit message")
        check(try git(["config", "--local", "user.name"], at: root) == "Repository Author\n")
        check(try git(["config", "--local", "user.email"], at: root) == "author@example.invalid\n")
        check(try git(["rev-parse", "HEAD"], at: root) == parent)
        let reopened = try await SourceControlService().perform(.refresh, in: root)
        precondition(reopened.identity == .init(name: "Repository Author", email: "author@example.invalid"))
        for invalid in [SourceControlIdentity(name: "", email: "valid@example.invalid"),
                        .init(name: "Bad\nName", email: "valid@example.invalid"),
                        .init(name: "Valid", email: "bad email"), .init(name: "<Bad>", email: "valid@example.invalid")] {
            do {
                _ = try await SourceControlService().saveIdentity(invalid, in: root)
                fatalError("Invalid identity accepted")
            } catch {}
        }
        check(try git(["config", "--local", "user.name"], at: root) == "Repository Author\n")
        let lock = root.appendingPathComponent(".git/refs/heads/main.lock")
        try Data().write(to: lock)
        await model.run(.commit(model.commitMessage))
        precondition(model.errorMessage?.contains("lock") == true, "Ref-lock errors must explain the failure")
        check(try git(["rev-parse", "HEAD"], at: root) == parent)
        precondition(FileManager.default.fileExists(atPath: lock.path), "Never remove another writer's lock")
        try FileManager.default.removeItem(at: lock)

        await model.run(.commit(model.commitMessage))
        precondition(model.errorMessage == nil && model.commitMessage.isEmpty && model.resultMessage != nil)
        check(try git(["rev-parse", "HEAD^"], at: root) == parent)
        check(try git(["show", "HEAD:tracked.txt"], at: root) == "staged\n")
        check(try git(["log", "-1", "--format=%an|%ae|%cn|%ce"], at: root)
              == "Repository Author|author@example.invalid|Repository Author|author@example.invalid\n")
        check(try String(contentsOf: file, encoding: .utf8) == "unstaged\n")
        precondition(model.snapshot?.changes.first?.staged == false && model.snapshot?.changes.first?.unstaged == true)
        print("Existing-repository checks passed: missing identity setup, local config persistence, validation, authored commit, safe retry, staged-only content, preserved working tree.")
    }

    @MainActor static func checkAppIdentity(at root: URL, defaults: UserDefaults) async throws {
        let settings = SourceControlIdentitySettings(defaults: defaults)
        precondition(settings.identity == .init(name: "Repository Author", email: "author@example.invalid"),
                     "App default must survive reopening settings")
        settings.draft = .init(name: "  App Author  ", email: "  app@example.invalid  ")
        settings.save()
        precondition(settings.errorMessage == nil)
        let expectedDefault = SourceControlIdentity(name: "App Author", email: "app@example.invalid")
        precondition(settings.identity == expectedDefault)
        settings.draft = .init(name: "Bad\nName", email: "app@example.invalid")
        settings.save()
        precondition(settings.errorMessage != nil && settings.identity == expectedDefault)

        // Empty local entries reliably mask any global identity on the test machine.
        for (index, configured) in [SourceControlIdentity(), .init(name: "Repo Name", email: ""),
                                    .init(name: "", email: "repo@example.invalid"),
                                    .init(name: "Repo Name", email: "repo@example.invalid")].enumerated() {
            let repo = root.appendingPathComponent("default-identity-\(index)")
            try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
            try git(["init", "-b", "main"], at: repo)
            try git(["config", "user.name", configured.name], at: repo)
            try git(["config", "user.email", configured.email], at: repo)
            let before = try Data(contentsOf: repo.appendingPathComponent(".git/config"))
            let model = SourceControlModel(directory: repo,
                identitySettings: SourceControlIdentitySettings(defaults: defaults))
            await model.run(.refresh)
            precondition(model.errorMessage == nil && !model.needsIdentity && !model.isEditingIdentity)
            check(try Data(contentsOf: repo.appendingPathComponent(".git/config")) == before)
            let file = repo.appendingPathComponent("file.txt")
            try "contents\n".write(to: file, atomically: true, encoding: .utf8)
            await model.run(.stage("file.txt"))
            model.commitMessage = "Use saved identity"
            precondition(model.canCommit)
            await model.run(.commit(model.commitMessage))
            precondition(model.errorMessage == nil)
            let expected = configured.fillingMissingValues(from: expectedDefault)
            check(try git(["log", "-1", "--format=%an|%ae|%cn|%ce"], at: repo)
                == "\(expected.name)|\(expected.email)|\(expected.name)|\(expected.email)\n")
            check(try git(["config", "--local", "user.name"], at: repo) == expected.name + "\n")
            check(try git(["config", "--local", "user.email"], at: repo) == expected.email + "\n")
        }
        settings.clear()
        precondition(SourceControlIdentitySettings(defaults: defaults).identity == nil)
        let savedRepo = root.appendingPathComponent("default-identity-0")
        let saved = try await SourceControlService().perform(.refresh, in: savedRepo)
        precondition(saved.identity == expectedDefault, "Clearing the app default must preserve repository config")
        try git(["config", "user.name", ""], at: savedRepo)
        let model = SourceControlModel(directory: savedRepo, identitySettings: settings)
        await model.run(.refresh)
        precondition(model.needsIdentity && model.isEditingIdentity)
        print("App identity checks passed: isolated preference persistence, remember from repository, normalization, validation, reuse, config precedence, read-only refresh, clearing without altering repositories.")
    }

    static func check(_ condition: Bool) { precondition(condition) }

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
        precondition(process.terminationStatus == 0, "Fixture git command failed: \(arguments.first ?? "")")
        return String(decoding: data, as: UTF8.self)
    }
}
