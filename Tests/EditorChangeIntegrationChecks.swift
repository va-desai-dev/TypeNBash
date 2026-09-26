import Foundation
@testable import TypeNBash

@main
struct EditorChangeIntegrationChecks {
    @MainActor static func main() async throws {
        let service = EditorChangeService()
        func compare(_ old: String, _ new: String) async -> EditorLineChanges {
            await service.changes(text: new, savedText: old, fileURL: nil)
        }
        var result = await compare("one\ntwo\n", "one\ntwo\n")
        precondition(result == .init())
        result = await compare("one\nthree\n", "one\ntwo\nthree\n")
        precondition(result.lines == [2: .added] && result.deletions.isEmpty)
        result = await compare("one\ntwo\nthree\n", "one\nchanged\nthree\n")
        precondition(result.lines == [2: .modified])
        result = await compare("one\ntwo\nthree\n", "two\nthree\n")
        precondition(result.deletions == [1] && result.lines.isEmpty)
        result = await compare("one\ntwo\nthree\n", "one\nthree\n")
        precondition(result.deletions == [2])
        result = await compare("one\ntwo\n", "one\n")
        precondition(result.deletions == [2])
        result = await compare("one\n", "")
        precondition(result.deletions == [1])
        result = await compare("", "first")
        precondition(result.lines == [1: .added])
        result = await compare("α\r\nold\r\n", "α\r\n👩🏽‍💻\r\n")
        precondition(result.lines == [2: .modified])
        result = await compare("one", "one\n")
        precondition(result.lines == [1: .modified])
        result = await compare("a\n", String(repeating: "x", count: 2 * 1024 * 1024 + 1))
        precondition(result == .init())

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("centcom-gutter-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/git")
            process.currentDirectoryURL = root
            process.arguments = args
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        let file = root.appendingPathComponent("test café [1].swift")
        result = await service.changes(text: "new\n", savedText: "old\n", fileURL: file)
        precondition(result.lines == [1: .modified], "Non-repository uses saved text")
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        result = await service.changes(text: "first\n", savedText: "first\n", fileURL: file)
        precondition(result.lines == [1: .added], "Unborn repository has an empty baseline")
        try "first\nold\nlast\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."])
        try git(["commit", "-m", "Fixture"])
        try "first\nstaged\nlast\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."])
        result = await service.changes(text: "first\nstaged\nlast\nunsaved\n",
                                       savedText: "first\nstaged\nlast\n", fileURL: file)
        precondition(result.lines == [2: .modified, 4: .added], "HEAD includes staged and unsaved changes: \(result)")
        try git(["commit", "-m", "Update"])
        result = await service.changes(text: "first\nstaged\nlast\n", savedText: "ignored", fileURL: file)
        precondition(result == .init(), "Commit refreshes the baseline")
        result = await service.changes(text: "new\n", savedText: "new\n", fileURL: root.appendingPathComponent("new.swift"))
        precondition(result.lines == [1: .added], "Untracked file is all added")
        let model = FileBrowserModel()
        model.select(WorkspaceFileEntry(url: file, isDirectory: false, byteCount: nil))
        for _ in 0..<200 {
            if case .text = model.preview { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        precondition(model.savedPreviewText == "first\nstaged\nlast\n")
        model.updatePreviewText("saved edit\n")
        model.save()
        model.updatePreviewText("newer unsaved edit\n")
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.savedPreviewText == "saved edit\n" && model.hasUnsavedChanges,
                     "Save baseline uses the written snapshot without clearing newer edits")
        model.save()
        model.newFile()
        for _ in 0..<200 where model.isSaving { try await Task.sleep(for: .milliseconds(10)) }
        precondition(model.savedPreviewText.isEmpty && model.isUntitled,
                     "Finishing a previous file's save cannot replace the new file's baseline")
        print("Editor change checks passed: line mapping, boundaries, CRLF/Unicode, saved fallback, Git HEAD, staging, commits, new files, size limit.")
    }
}
