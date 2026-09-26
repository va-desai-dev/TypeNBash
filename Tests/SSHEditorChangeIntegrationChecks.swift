import Foundation
@testable import TypeNBash

@MainActor
private final class RemoteFixture: WorkspaceFileSystem {
    let homeDirectory = URL(filePath: "/remote")
    var contents = "first\nsaved edit\nlast\n"
    var baseline = "first\ncommitted\nlast\n"
    var requests = 0
    var fails = false
    var delays = false
    var pending: CheckedContinuation<String?, Error>?

    func contentsOfDirectory(at directory: URL, includingHiddenFiles: Bool) async throws -> [WorkspaceFileEntry] { [] }
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data { Data(contents.utf8) }
    func writeFile(_ data: Data, to url: URL) async throws { contents = String(decoding: data, as: UTF8.self) }
    func createDirectory(at url: URL) async throws {}
    func editorGitBaseline(at url: URL) async throws -> String? {
        requests += 1
        if delays { return try await withCheckedThrowingContinuation { pending = $0 } }
        if fails { throw URLError(.networkConnectionLost) }
        return baseline
    }
}

@main
struct SSHEditorChangeIntegrationChecks {
    @MainActor static func main() async throws {
        func waitFor(_ condition: () -> Bool) async throws {
            for _ in 0..<300 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            preconditionFailure("Remote baseline did not reach the expected state")
        }
        let fs = RemoteFixture()
        let model = FileBrowserModel(fileSystem: fs)
        let file = WorkspaceFileEntry(url: URL(filePath: "/remote/source.swift"), isDirectory: false, byteCount: nil)
        model.select(file)
        try await waitFor { model.editorGitBaseline == fs.baseline }
        precondition(!model.comparesEditorWithGit, "Remote paths never access this Mac's Git repository")
        precondition(model.savedPreviewText == fs.contents)
        let service = EditorChangeService()
        let draft = "first\nsaved edit\nlast\nunsaved\n"
        model.updatePreviewText(draft)
        try await Task.sleep(for: .milliseconds(300))
        precondition(fs.requests == 1, "Typing uses the cached baseline without SSH requests")
        var changes = await service.changes(text: draft, savedText: model.editorGitBaseline!, fileURL: nil)
        precondition(changes.lines == [2: .modified, 4: .added], "Remote saved and unsaved changes share HEAD")
        model.save()
        try await waitFor { !model.isSaving && fs.requests == 2 }
        precondition(model.editorGitBaseline == fs.baseline, "Saving does not erase remote Git changes")

        fs.baseline = draft
        model.refreshEditorGitBaseline()
        try await waitFor { model.editorGitBaseline == draft }
        changes = await service.changes(text: draft, savedText: model.editorGitBaseline!, fileURL: nil)
        precondition(changes == .init(), "Remote commit refresh clears changes")
        if case .text(let text) = model.preview { precondition(text == draft) } else { preconditionFailure() }

        fs.delays = true
        model.refreshEditorGitBaseline()
        try await waitFor { fs.pending != nil }
        let replacement = RemoteFixture()
        replacement.baseline = "different host\n"
        model.use(fileSystem: replacement, initialDirectory: replacement.homeDirectory)
        model.select(file)
        try await waitFor { model.editorGitBaseline == replacement.baseline }
        fs.pending?.resume(returning: "stale host reply\n")
        fs.pending = nil
        try await Task.sleep(for: .milliseconds(30))
        precondition(model.editorGitBaseline == replacement.baseline, "Late replies cannot cross hosts with identical paths")

        replacement.fails = true
        model.refreshEditorGitBaseline()
        try await waitFor { model.editorGitBaseline == nil }
        precondition(model.savedPreviewText == replacement.contents, "Disconnected SSH falls back to saved text")
        model.newFile()
        precondition(model.editorGitBaseline == nil && model.savedPreviewText.isEmpty)
        print("SSH editor checks passed: cached HEAD, saved/unsaved markers, save/commit refresh, draft preservation, stale-host isolation, disconnected fallback.")
    }
}
