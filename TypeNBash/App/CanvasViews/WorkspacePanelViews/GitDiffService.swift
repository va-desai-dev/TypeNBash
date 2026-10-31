import Foundation
import libgit2
import SwiftUI
internal import URLUtils

/// Uncommitted is everything since HEAD, staged or not — staging is per file,
/// so each row's badge shows it. Committed is what a push would send, and
/// only exists for a branch that tracks an upstream.
nonisolated enum GitDiffScope: String, CaseIterable, Identifiable, Sendable {
    case uncommitted = "UNCOMMITTED", committed = "COMMITTED"
    var id: Self { self }
    var leftTitle: String { self == .committed ? "Upstream" : "HEAD" }
    var rightTitle: String { self == .committed ? "HEAD" : "Working Tree (saved files)" }
}

/// How a file changed. Both loaders — libgit2 locally, `git diff
/// --name-status` over SSH — map into this, so the badge letter and color are
/// decided once rather than by a `switch` in each.
nonisolated enum GitDiffStatus: String, Sendable {
    case added = "Added", modified = "Modified", deleted = "Deleted",
         renamed = "Renamed", conflicted = "Conflict"

    /// The letter Xcode's navigator badges the file with.
    var letter: String {
        switch self {
        case .added: "A"
        case .modified: "M"
        case .deleted: "D"
        case .renamed: "R"
        case .conflicted: "U"
        }
    }

    @MainActor var color: Color {
        switch self {
        case .added: .diffAdded
        case .modified, .renamed: .blue
        case .deleted: .diffRemoved
        case .conflicted: .yellow
        }
    }
}

nonisolated struct GitDiffFile: Identifiable, Sendable {
    let path: String
    let oldPath: String
    let status: GitDiffStatus
    /// Whether the change is in the index, the working tree, or both. Read
    /// from the repository's status rather than from which comparison listed
    /// the file, so the All list can tell staged edits from unstaged ones.
    let staged: Bool
    let unstaged: Bool
    var id: String { path }

    var tipMessage: String {
        if status == .added { return "Added \(label)" }
        if status == .deleted { return "Deleted \(label)" }
        if status == .conflicted { return "\(label) has a conflicting file of same path" }
        if status == .modified { return "Modified \(label)" }
        if status == .renamed && oldPath != path { return "Moved \(label) from \(oldPath) to \(path)" }
        if status == .renamed { return "\(label) was renamed" }
        else { return "Unknown status" }
    }

    var label: String {
        let fileURL = URL(filePath: path)
        return fileURL.lastPathComponent.deletingPathExtension
    }

    /// The same icon the file browser shows for this file.
    var icon: FileTypeIcon { WorkspaceFileEntry.icon(for: URL(filePath: path)) }
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

/// Lines added and removed across every file in the comparison, not just the
/// one being shown. Binary files count as neither, as in `git diff --stat`.
nonisolated struct GitDiffStats: Sendable {
    var insertions = 0
    var deletions = 0
}

nonisolated struct GitDiffResult: Sendable {
    let files: [GitDiffFile]
    let selectedPath: String?
    let rows: [GitDiffRow]
    let message: String?
    var stats = GitDiffStats()
    /// Whether the branch tracks an upstream. Without one, a Committed request
    /// loads Uncommitted instead.
    var hasUpstream = false
}

actor GitDiffService {
    func load(directory: URL, scope requestedScope: GitDiffScope, selectedPath: String?) throws -> GitDiffResult {
        let root = try SourceControlService.repositoryRoot(in: directory)
        guard git_libgit2_init() >= 0 else { throw GitDiffError.failed }
        defer { git_libgit2_shutdown() }
        var repo: OpaquePointer?
        guard git_repository_open(&repo, root.path) == 0, let repo else { throw GitDiffError.failed }
        defer { git_repository_free(repo) }
        var tree: OpaquePointer?
        if git_repository_head_unborn(repo) != 1 {
            var object: OpaquePointer?
            guard git_revparse_single(&object, repo, "HEAD^{tree}") == 0 else { throw GitDiffError.failed }
            tree = object
        }
        defer { git_tree_free(tree) }
        let baseTree = upstreamBaseTree(in: repo)
        defer { git_tree_free(baseTree) }
        let hasUpstream = baseTree != nil
        let scope = hasUpstream ? requestedScope : .uncommitted
        var options = git_diff_options()
        guard git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)) == 0 else { throw GitDiffError.failed }
        options.flags = GIT_DIFF_INCLUDE_UNTRACKED.rawValue | GIT_DIFF_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_DIFF_SHOW_UNTRACKED_CONTENT.rawValue
        options.max_size = 2 * 1024 * 1024
        options.context_lines = 3
        var diff: OpaquePointer?
        let status: Int32
        switch scope {
        case .uncommitted: status = git_diff_tree_to_workdir_with_index(&diff, repo, tree, &options)
        case .committed: status = git_diff_tree_to_tree(&diff, repo, baseTree, tree, &options)
        }
        guard status == 0, let diff else { throw GitDiffError.failed }
        defer { git_diff_free(diff) }
        var find = git_diff_find_options()
        if git_diff_find_options_init(&find, UInt32(GIT_DIFF_FIND_OPTIONS_VERSION)) == 0 {
            find.flags = GIT_DIFF_FIND_RENAMES.rawValue
            _ = git_diff_find_similar(diff, &find)
        }
        // Totals for the whole diff, which libgit2 counts by generating every
        // file's patch; untracked files count because of SHOW_UNTRACKED_CONTENT.
        var stats = GitDiffStats()
        var diffStats: OpaquePointer?
        if git_diff_get_stats(&diffStats, diff) == 0, let diffStats {
            stats = GitDiffStats(insertions: git_diff_stats_insertions(diffStats),
                                 deletions: git_diff_stats_deletions(diffStats))
            git_diff_stats_free(diffStats)
        }
        let stages = scope == .uncommitted ? stageStates(in: repo) : [:]
        var files: [GitDiffFile] = []
        var indices: [String: Int] = [:]
        for index in 0..<git_diff_num_deltas(diff) {
            guard let delta = git_diff_get_delta(diff, index)?.pointee,
                  let rawPath = delta.new_file.path ?? delta.old_file.path else { continue }
            let path = String(cString: rawPath)
            let oldPath = delta.old_file.path.map { String(cString: $0) } ?? path
            let status: GitDiffStatus = switch delta.status {
            case GIT_DELTA_ADDED, GIT_DELTA_UNTRACKED: .added
            case GIT_DELTA_DELETED: .deleted
            case GIT_DELTA_RENAMED: .renamed
            case GIT_DELTA_CONFLICTED: .conflicted
            default: .modified
            }
            let stage = stages[path]
            files.append(GitDiffFile(path: path, oldPath: oldPath, status: status,
                                     staged: stage?.staged ?? (scope == .committed),
                                     unstaged: stage?.unstaged ?? (scope == .uncommitted)))
            indices[path] = index
        }
        files.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let relativeSelection = selectedPath.map { path in
            let prefix = root.path + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        let selection = relativeSelection.flatMap { indices[$0] == nil ? nil : $0 } ?? files.first?.path
        guard let selection, let index = indices[selection] else {
            return GitDiffResult(files: files, selectedPath: nil, rows: [], message: "No changes in this comparison.",
                                 stats: stats, hasUpstream: hasUpstream)
        }
        var patch: OpaquePointer?
        guard git_patch_from_diff(&patch, diff, index) == 0 else { throw GitDiffError.failed }
        defer { git_patch_free(patch) }
        guard let patch else {
            return GitDiffResult(files: files, selectedPath: selection, rows: [], message: "No text preview for this change.",
                                 stats: stats, hasUpstream: hasUpstream)
        }
        let delta = git_patch_get_delta(patch)!.pointee
        if delta.flags & GIT_DIFF_FLAG_BINARY.rawValue != 0 {
            return GitDiffResult(files: files, selectedPath: selection, rows: [],
                                 message: "Binary or large file. Text comparison is limited to 2 MB per file.",
                                 stats: stats, hasUpstream: hasUpstream)
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
                             message: truncated ? "Preview limited to 20,000 lines." : rows.isEmpty ? "No textual changes (file metadata or conflict)." : nil,
                             stats: stats, hasUpstream: hasUpstream)
    }

    /// The tree where the branch and its upstream diverged, so Committed is
    /// exactly what a push would send — upstream commits fetched but not yet
    /// merged don't show up reversed. Nil without an upstream.
    private func upstreamBaseTree(in repo: OpaquePointer) -> OpaquePointer? {
        var head: OpaquePointer?
        var upstream: OpaquePointer?
        defer {
            git_object_free(head)
            git_object_free(upstream)
        }
        for spec in upstreamCandidates(in: repo) where git_revparse_single(&upstream, repo, spec) == 0 { break }
        guard git_revparse_single(&head, repo, "HEAD") == 0, let head, let upstream else { return nil }
        var base = git_oid()
        guard git_merge_base(&base, repo, git_object_id(head), git_object_id(upstream)) == 0 else { return nil }
        var commit: OpaquePointer?
        guard git_commit_lookup(&commit, repo, &base) == 0, let commit else { return nil }
        defer { git_commit_free(commit) }
        var tree: OpaquePointer?
        return git_commit_tree(&tree, commit) == 0 ? tree : nil
    }

    /// What the branch would be pushed against, most specific first: its
    /// upstream, else the same-named branch on the remote (pushed without
    /// `-u`), else the remote's default branch (never pushed).
    private func upstreamCandidates(in repo: OpaquePointer) -> [String] {
        var names = git_strarray()
        guard git_remote_list(&names, repo) == 0 else { return ["@{upstream}"] }
        defer { git_strarray_dispose(&names) }
        let remotes = (0..<names.count).compactMap { names.strings[$0].map { String(cString: $0) } }
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else { return ["@{upstream}"] }
        var reference: OpaquePointer?
        defer { git_reference_free(reference) }
        let branch = git_repository_head(&reference, repo) == 0 && git_reference_is_branch(reference) == 1
            ? git_reference_shorthand(reference).map { String(cString: $0) } : nil
        return ["@{upstream}"] + (branch.map { ["refs/remotes/\(remote)/\($0)"] } ?? [])
            + ["refs/remotes/\(remote)/HEAD"]
    }

    /// Each changed path's index and working-tree state, keyed by both sides
    /// of a rename so the comparison's paths find it. Empty if status fails,
    /// in which case rows fall back to the comparison's scope.
    private func stageStates(in repo: OpaquePointer) -> [String: (staged: Bool, unstaged: Bool)] {
        var options = git_status_options()
        guard git_status_options_init(&options, UInt32(GIT_STATUS_OPTIONS_VERSION)) == 0 else { return [:] }
        options.show = GIT_STATUS_SHOW_INDEX_AND_WORKDIR
        options.flags = GIT_STATUS_OPT_INCLUDE_UNTRACKED.rawValue | GIT_STATUS_OPT_RECURSE_UNTRACKED_DIRS.rawValue
            | GIT_STATUS_OPT_RENAMES_HEAD_TO_INDEX.rawValue
        var list: OpaquePointer?
        guard git_status_list_new(&list, repo, &options) == 0, let list else { return [:] }
        defer { git_status_list_free(list) }
        let indexFlags = GIT_STATUS_INDEX_NEW.rawValue | GIT_STATUS_INDEX_MODIFIED.rawValue
            | GIT_STATUS_INDEX_DELETED.rawValue | GIT_STATUS_INDEX_RENAMED.rawValue
            | GIT_STATUS_INDEX_TYPECHANGE.rawValue
        let workTreeFlags = GIT_STATUS_WT_NEW.rawValue | GIT_STATUS_WT_MODIFIED.rawValue
            | GIT_STATUS_WT_DELETED.rawValue | GIT_STATUS_WT_RENAMED.rawValue
            | GIT_STATUS_WT_TYPECHANGE.rawValue | GIT_STATUS_CONFLICTED.rawValue
        var states: [String: (staged: Bool, unstaged: Bool)] = [:]
        for index in 0..<git_status_list_entrycount(list) {
            guard let entry = git_status_byindex(list, index)?.pointee else { continue }
            let flags = entry.status.rawValue
            let state = (staged: flags & indexFlags != 0, unstaged: flags & workTreeFlags != 0)
            for delta in [entry.head_to_index, entry.index_to_workdir] {
                guard let file = delta?.pointee else { continue }
                for raw in [file.old_file.path, file.new_file.path] {
                    if let raw { states[String(cString: raw)] = state }
                }
            }
        }
        return states
    }
}

nonisolated enum GitDiffError: LocalizedError {
    case failed
    var errorDescription: String? { "Couldn’t load the Git comparison. Refresh and try again." }
}
