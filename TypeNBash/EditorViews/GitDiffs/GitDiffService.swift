import Foundation
import libgit2

nonisolated enum GitDiffScope: String, CaseIterable, Identifiable, Sendable {
    case all = "All Changes", unstaged = "Unstaged", staged = "Staged"
    var id: Self { self }
    var leftTitle: String { self == .unstaged ? "Index" : "HEAD" }
    var rightTitle: String { self == .staged ? "Index" : "Working Tree (saved files)" }
}

nonisolated struct GitDiffFile: Identifiable, Sendable {
    let path: String
    let oldPath: String
    let status: String
    var id: String { path }

    /// The same symbol the file browser shows for this file.
    var icon: String { WorkspaceFileEntry.icon(for: URL(filePath: path)) }
}

nonisolated struct GitDiffLine: Sendable {
    let number: Int?
    let text: String
    let changed: Bool
}

nonisolated struct GitDiffRow: Identifiable, Sendable {
    let id: Int
    let left: GitDiffLine?
    let right: GitDiffLine?
    var isHeader = false
}

nonisolated struct GitDiffResult: Sendable {
    let files: [GitDiffFile]
    let selectedPath: String?
    let rows: [GitDiffRow]
    let message: String?
}

actor GitDiffService {
    func load(directory: URL, scope: GitDiffScope, selectedPath: String?) throws -> GitDiffResult {
        let root = try SourceControlService.repositoryRoot(in: directory)
        guard git_libgit2_init() >= 0 else { throw GitDiffError.failed }
        defer { git_libgit2_shutdown() }
        var repo: OpaquePointer?
        guard git_repository_open(&repo, root.path) == 0, let repo else { throw GitDiffError.failed }
        defer { git_repository_free(repo) }
        var tree: OpaquePointer?
        if scope != .unstaged && git_repository_head_unborn(repo) != 1 {
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, "HEAD^{tree}") == 0 else { throw GitDiffError.failed }
            tree = object
        }
        defer { git_tree_free(tree) }
        var options = git_diff_options()
        guard git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)) == 0 else { throw GitDiffError.failed }
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        options.max_size = 2 * 1024 * 1024
        options.context_lines = 3
        var diff: OpaquePointer?
        let status: Int32
        switch scope {
        case .all: status = git_diff_tree_to_workdir_with_index(&diff, repo, tree, &options)
        case .staged: status = git_diff_tree_to_index(&diff, repo, tree, nil, &options)
        case .unstaged: status = git_diff_index_to_workdir(&diff, repo, nil, &options)
        }
        guard status == 0, let diff else { throw GitDiffError.failed }
        defer { git_diff_free(diff) }
        var find = git_diff_find_options()
        if git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)) == 0 {
            find.flags = GIT_DIFF_FIND_RENAMES.rawValue
            _ = git_diff_find_similar(diff, &find)
        }
        var files: [GitDiffFile] = []
        var indices: [String: Int] = [:]
        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index)?.pointee,
                  let rawPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let path = String(cString: rawPath)
            let oldPath = delta.old_file.path.map { String(cString: $0) } ?? path
            let label: String
            switch delta.status {
            case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED: label = "Added"
            case GIT_DELTA_DELETED: label = "Deleted"
            case GIT_DELTA_RENAMED: label = "Renamed"
            case GIT_DELTA_CONFLICTED: label = "Conflict"
            default: label = "Modified"
            }
            files.append(GitDiffFile(path: path, oldPath: oldPath, status: label))
            indices[path] = index
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let relativeSelection = selectedPath.map { path in
            let prefix = root.path + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        let selection = relativeSelection.flatMap { indices[$0] == nil ? nil : $0 } ?? files.first?.path
        guard let selection, let index = indices[selection] else {
            return GitDiffResult(files: files, selectedPath: nil, rows: [], message: "No changes in this comparison.")
        }
        var patch: OpaquePointer?
        guard git_patch_from_diff(&patch, diff, index) == 0 else { throw GitDiffError.failed }
        defer { git_patch_free(patch) }
        guard let patch else {
            return GitDiffResult(files: files, selectedPath: selection, rows: [], message: "No text preview for this change.")
        }
        let delta = git_patch_get_delta(patch)!.pointee
        if delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0 {
            return GitDiffResult(files: files, selectedPath: selection, rows: [],
                                 message: "Binary or large file. Text comparison is limited to 2 MB per file.")
        }
        var rows: [GitDiffRow] = []
        var removed: [GitDiffLine] = []
        var added: [GitDiffLine] = []
        func flush() {
            for line in removed {
                rows.append(GitDiffRow(id: rows.count, left: line, right: nil))
            }
            for line in added {
                rows.append(GitDiffRow(id: rows.count, left: nil, right: line))
            }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        var truncated = false
        hunks: for hunkIndex in 0..<git_patch_num_hunks(patch) {
            var hunk: UnsafePointer<git_diff_hunk>?
            var count = 0
            guard git_patch_get_hunk(&hunk, &count, patch, hunkIndex) == 0, let hunk else { throw GitDiffError.failed }
            let header = "@@ −\(hunk.pointee.old_start),\(hunk.pointee.old_lines) +\(hunk.pointee.new_start),\(hunk.pointee.new_lines) @@"
            let label = GitDiffLine(number: nil, text: header, changed: false)
            rows.append(GitDiffRow(id: rows.count, left: label, right: label, isHeader: true))
            for lineIndex in 0..<count {
                if rows.count + removed.count + added.count >= 20_000 { truncated = true; break hunks }
                var line: UnsafePointer<git_diff_line>?
                guard git_patch_get_line_in_hunk(&line, patch, hunkIndex, lineIndex) == 0, let line else { throw GitDiffError.failed }
                let value = line.pointee
                let bytes = UnsafeRawBufferPointer(start: value.content, count: min(value.content_len, 10_000))
                var text = String(decoding: bytes, as: UTF8.self)
                if text.hasSuffix("\n") { text.removeLast() }
                if text.hasSuffix("\r") { text.removeLast() }
                if value.content_len > 10_000 { text += " … [line truncated]" }
                switch value.origin {
                case 45: removed.append(GitDiffLine(number: Int(value.old_lineno), text: text, changed: true))
                case 43: added.append(GitDiffLine(number: Int(value.new_lineno), text: text, changed: true))
                case 32:
                    flush()
                    rows.append(GitDiffRow(id: rows.count,
                                           left: GitDiffLine(number: Int(value.old_lineno), text: text, changed: false),
                                           right: GitDiffLine(number: Int(value.new_lineno), text: text, changed: false)))
                default:
                    flush()
                    let note = GitDiffLine(number: nil, text: "No newline at end of file", changed: false)
                    rows.append(GitDiffRow(id: rows.count, left: note, right: note, isHeader: true))
                }
            }
            flush()
        }
        flush()
        return GitDiffResult(files: files, selectedPath: selection, rows: rows,
                             message: truncated ? "Preview limited to 20,000 lines." : rows.isEmpty ? "No textual changes (file metadata or conflict)." : nil)
    }
}

nonisolated enum GitDiffError: LocalizedError {
    case failed
    var errorDescription: String? { "Couldn’t load the Git comparison. Refresh and try again." }
}
