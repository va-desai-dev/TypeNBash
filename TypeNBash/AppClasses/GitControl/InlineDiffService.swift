import Foundation
import libgit2

nonisolated struct EditorLineChanges: Equatable, Sendable {
    enum Kind: Sendable { case added, modified }
    var lines: [Int: Kind] = [:]
    /// One-based line immediately after a removed block; may be past EOF.
    var deletions: Set<Int> = []
}

/// Compares the live buffer off the UI actor. No files or index entries are written.
actor EditorChangeService {
    func changes(text: String, savedText: String, fileURL: URL?) -> EditorLineChanges {
        guard !Task.isCancelled, text.utf8.count <= 2 * 1024 * 1024,
              git_libgit2_init() >= 0 else { return .init() }
        defer { git_libgit2_shutdown() }
        let baseline = fileURL.flatMap { headContents(for: $0) } ?? savedText
        guard baseline != text, baseline.utf8.count <= 2 * 1024 * 1024 else { return .init() }
        let old = Data(baseline.utf8), new = Data(text.utf8)
        var options = git_diff_options()
        guard git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION)) == 0 else { return .init() }
        options.context_lines = 0
        var patch: OpaquePointer?
        let status = old.withUnsafeBytes { oldBytes in
            new.withUnsafeBytes { newBytes in
                git_patch_from_buffers(&patch, oldBytes.baseAddress, oldBytes.count, nil,
                                       newBytes.baseAddress, newBytes.count, nil, &options)
            }
        }
        defer { git_patch_free(patch) }
        guard status == 0, let patch else { return .init() }
        var changes = EditorLineChanges()
        for index in 0..<git_patch_num_hunks(patch) {
            guard !Task.isCancelled else { return .init() }
            var hunk: UnsafePointer<git_diff_hunk>?
            var count = 0
            guard git_patch_get_hunk(&hunk, &count, patch, index) == 0, let hunk else { continue }
            let value = hunk.pointee
            if value.new_lines == 0 {
                changes.deletions.insert(Int(value.new_start) + 1)
            } else {
                let kind: EditorLineChanges.Kind = value.old_lines == 0 ? .added : .modified
                for line in Int(value.new_start)..<Int(value.new_start + value.new_lines) {
                    changes.lines[line] = kind
                }
            }
        }
        return changes
    }

    /// nil means no usable Git baseline; an absent HEAD path is a new file.
    private func headContents(for url: URL) -> String? {
        guard url.isFileURL,
              let root = try? SourceControlService.repositoryRoot(in: url.deletingLastPathComponent()) else { return nil }
        var repo: OpaquePointer?
        guard git_repository_open(&repo, root.path) == 0, let repo else { return nil }
        defer { git_repository_free(repo) }
        if git_repository_head_unborn(repo) == 1 { return "" }
        var tree: OpaquePointer?
        guard git_revparse_single(&tree, repo, "HEAD^{tree}") == 0, let tree else { return nil }
        defer { git_object_free(tree) }
        let path = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
        var entry: OpaquePointer?
        var status = git_tree_entry_bypath(&entry, tree, path)
        // macOS filenames may use a different Unicode normalization than the Git tree.
        for spelling in [path.decomposedStringWithCanonicalMapping, path.precomposedStringWithCanonicalMapping]
            where status == GIT_ENOTFOUND.rawValue {
            status = git_tree_entry_bypath(&entry, tree, spelling)
        }
        if status == GIT_ENOTFOUND.rawValue { return "" }
        guard status == 0, let entry else { return nil }
        defer { git_tree_entry_free(entry) }
        guard git_tree_entry_type(entry) == GIT_OBJECT_BLOB else { return nil }
        var blob: OpaquePointer?
        guard git_blob_lookup(&blob, repo, git_tree_entry_id(entry)) == 0, let blob else { return nil }
        defer { git_blob_free(blob) }
        let size = git_blob_rawsize(blob)
        guard size <= 2 * 1024 * 1024, git_blob_is_binary(blob) == 0 else { return nil }
        guard size > 0 else { return "" }
        guard let bytes = git_blob_rawcontent(blob) else { return nil }
        return String(data: Data(bytes: bytes, count: Int(size)), encoding: .utf8)
    }
}
