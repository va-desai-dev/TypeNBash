import Foundation
import AppKit
import SwiftUI
@testable import TypeNBash

@main
struct GitDiffIntegrationChecks {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("centcom-diff-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        func git(_ args: [String]) throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = args
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            precondition(process.terminationStatus == 0)
        }
        try git(["init", "-b", "main"])
        try git(["config", "user.name", "Fixture"])
        try git(["config", "user.email", "fixture@example.invalid"])
        let path = "example [1] café.txt"
        let file = root.appendingPathComponent(path)
        let service = GitDiffService()
        try "first\nold\nlast\n".write(to: file, atomically: true, encoding: .utf8)
        var result = try await service.load(directory: root, scope: .uncommitted, selectedPath: file.path)
        precondition(result.selectedPath == path && result.rows.contains { $0.right?.text == "old" && $0.right?.changed == true })
        precondition(result.rows.filter { !$0.isHeader }.allSatisfy { $0.left == nil })
        try git(["add", "--", path])
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: path)
        precondition(result.files.first.map { $0.staged && !$0.unstaged } == true)
        try git(["commit", "-m", "Fixture"])
        try "first\nnew staged\nlast\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "--", path])
        try "first\nnew unstaged\nlast\n".write(to: file, atomically: true, encoding: .utf8)
        // No upstream: a Committed request falls back to Uncommitted.
        result = try await service.load(directory: root, scope: .committed, selectedPath: path)
        precondition(!result.hasUpstream)
        precondition(result.files.first.map { $0.staged && $0.unstaged } == true)
        let combinedRemoved = result.rows.firstIndex { $0.left?.text == "old" && $0.left?.changed == true }!
        let combinedAdded = result.rows.firstIndex { $0.right?.text == "new unstaged" && $0.right?.changed == true }!
        precondition(combinedRemoved < combinedAdded)
        precondition(result.rows.contains { $0.left?.number == 2 && $0.right == nil })
        precondition(result.rows.contains { $0.right?.number == 2 && $0.left == nil })
        try FileManager.default.removeItem(at: file)
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: path)
        precondition(result.files.first?.status == .deleted)
        precondition(result.rows.filter { !$0.isHeader }.allSatisfy { $0.right == nil })
        let binary = root.appendingPathComponent("binary.dat")
        try Data([0, 1, 2, 3]).write(to: binary)
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: "binary.dat")
        precondition(result.rows.isEmpty && result.message != nil)
        let large = root.appendingPathComponent("large.txt")
        try Data(repeating: 65, count: 2 * 1024 * 1024 + 1).write(to: large)
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: "large.txt")
        precondition(result.rows.isEmpty && result.message != nil)
        try git(["reset", "--hard", "HEAD"])
        try FileManager.default.removeItem(at: binary)
        try FileManager.default.removeItem(at: large)
        try git(["mv", path, "renamed.txt"])
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: "renamed.txt")
        precondition(result.files.contains { $0.status == .renamed && $0.oldPath == path })
        try git(["commit", "-m", "Rename"])
        result = try await service.load(directory: root, scope: .uncommitted, selectedPath: nil)
        precondition(result.files.isEmpty && result.rows.isEmpty)
        // Track a bare upstream; a local commit stays in Committed until pushed.
        let upstream = root.deletingLastPathComponent().appendingPathComponent("\(root.lastPathComponent)-upstream.git")
        defer { try? FileManager.default.removeItem(at: upstream) }
        try git(["init", "--bare", "-b", "main", upstream.path])
        try git(["remote", "add", "origin", upstream.path])
        try git(["push", "-u", "origin", "main"])
        try "first\nunpushed\nlast\n".write(to: root.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
        try git(["commit", "-am", "Unpushed"])
        result = try await service.load(directory: root, scope: .committed, selectedPath: "renamed.txt")
        precondition(result.hasUpstream && result.files.map(\.path) == ["renamed.txt"])
        precondition(result.rows.contains { $0.right?.text == "unpushed" && $0.right?.changed == true })
        try git(["push"])
        result = try await service.load(directory: root, scope: .committed, selectedPath: nil)
        precondition(result.files.isEmpty)
        if ProcessInfo.processInfo.environment["CENTCOM_DIFF_PREVIEW"] == "1" {
            try "first\nupdated line\nadditional line\nlast\n".write(to: root.appendingPathComponent("renamed.txt"), atomically: true, encoding: .utf8)
            _ = NSApplication.shared
            // The diff panes read settings, which the app registers at launch.
            AppDefaults.register()
            // The app owns the model and loads it, as AppContentView does.
            let model = GitDiffModel(directory: root, selectedFile: nil)
            await model.refresh()
            let host = NSHostingView(rootView: GitDiffView(model: model))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
                                  styleMask: [.titled, .resizable], backing: .buffered, defer: false)
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .seconds(2))
            host.layoutSubtreeIfNeeded()
            let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/centcom-diff-preview.png"))
            window.orderOut(nil)
        }
        print("Diff checks passed: initial/untracked files, stacked removals before additions, per-file staged state, no-upstream fallback, unpushed commits, deletion, binary/large files, renames, and clean repository.")
    }
}
