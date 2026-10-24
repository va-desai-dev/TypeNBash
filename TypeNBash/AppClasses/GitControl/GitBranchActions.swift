import Foundation
import libgit2
import SwiftGitX

/// A branch the Repositories tab can act on.
nonisolated struct GitBranchRef: Hashable, Sendable {
    /// The branch's own name, without any remote prefix.
    let branch: String
    /// Set for a remote-tracking branch.
    var remote: String?

    /// `main` or `origin/main`, as Git spells it in messages.
    var name: String { remote.map { "\($0)/\(branch)" } ?? branch }
    var fullName: String { remote.map { "refs/remotes/\($0)/\(branch)" } ?? "refs/heads/\(branch)" }
}

nonisolated enum GitRefAction: Sendable {
    /// A remote branch switches to its local counterpart, created and set to
    /// track it if there isn't one yet.
    case switchTo(GitBranchRef)
    /// Creates a branch at `from` and switches to it.
    case newBranch(String, from: GitBranchRef)
    /// Merges into the current branch.
    case merge(GitBranchRef)

    var title: String {
        switch self {
        case .switchTo: "Switch Branch"
        case .newBranch: "New Branch"
        case .merge: "Merge"
        }
    }

    /// Git validates the rest; this keeps a name from being read as an option.
    static func validatedBranchName(_ name: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !name.hasPrefix("-") else { throw GitRefActionError.invalidName }
        return name
    }
}

nonisolated enum GitMergeOutcome: Sendable {
    case upToDate, fastForward, merged
    /// The merge is left in progress with this many conflicted files.
    case conflicts(Int)

    func message(merging source: String, into target: String) -> String {
        switch self {
        case .upToDate: "“\(target)” already contains everything in “\(source)”."
        case .fastForward: "Fast-forwarded “\(target)” to “\(source)”."
        case .merged: "Merged “\(source)” into “\(target)” with a merge commit."
        case .conflicts(let count):
            "Merging “\(source)” into “\(target)” stopped with conflicts in \(count) \(count == 1 ? "file" : "files"). "
                + "Resolve them, stage the files, then commit to finish the merge."
        }
    }
}

nonisolated enum GitRefActionError: LocalizedError {
    case git(String), invalidName, stagedChanges, operationInProgress, noBranch, notACommit, missingIdentity
    var errorDescription: String? {
        switch self {
        case .git(let message): "Git: " + message
        case .invalidName: "Enter a branch name that doesn’t start with “-”."
        case .stagedChanges: "Commit or unstage your staged changes before merging, so they aren’t recorded in the merge commit."
        case .operationInProgress: "Finish the merge, revert or cherry-pick already in progress before starting another."
        case .noBranch: "Switch to a branch before merging into it."
        case .notACommit: "That branch doesn’t point to a commit."
        case .missingIdentity: "Set your commit name and email in Commit Identity before merging; a merge that can’t fast-forward records a commit."
        }
    }
}

extension SourceControlService {
    func perform(_ action: GitRefAction, in directory: URL,
                 defaultIdentity: SourceControlIdentity?) throws -> GitMergeOutcome? {
        let root = try Self.repositoryRoot(in: directory)
        let repository = try Repository(at: root, createIfNotExists: false)
        func branch(_ ref: GitBranchRef) throws -> Branch {
            try repository.branch.get(named: ref.name, type: ref.remote == nil ? .local : .remote)
        }
        // SwiftGitX checks out with GIT_CHECKOUT_SAFE, so a switch that would
        // overwrite uncommitted work fails rather than discarding it.
        switch action {
        case .switchTo(let ref):
            try repository.switch(to: branch(ref))
            return nil
        case .newBranch(let name, let source):
            let name = try GitRefAction.validatedBranchName(name)
            guard let commit = try branch(source).target as? Commit else { throw GitRefActionError.notACommit }
            try repository.switch(to: repository.branch.create(named: name, target: commit))
            return nil
        case .merge(let ref):
            // Only a merge commit needs an author, so a fast-forward goes ahead without one.
            let author = try? identity(in: repository).fillingMissingValues(from: defaultIdentity).validated()
            return try GitMerge.merge(ref, root: root, author: author)
        }
    }
}

extension RemoteGit {
    func perform(_ action: GitRefAction, in directory: URL) async throws -> GitMergeOutcome? {
        let root = try await repositoryRoot(in: directory)
        switch action {
        case .switchTo(let ref):
            guard ref.remote != nil else {
                _ = try await run(["switch", ref.branch], in: root)
                return nil
            }
            let exists = (try? await run(["rev-parse", "--verify", "-q", "refs/heads/\(ref.branch)"], in: root)) != nil
            _ = try await run(exists ? ["switch", ref.branch] : ["switch", "--track", "-c", ref.branch, ref.fullName],
                              in: root)
            return nil
        case .newBranch(let name, let source):
            // `--no-track`, as locally: a branch forked from `origin/main`
            // shouldn't push back to it.
            _ = try await run(["switch", "--no-track", "-c", GitRefAction.validatedBranchName(name), source.fullName],
                              in: root)
            return nil
        case .merge(let ref):
            do {
                let output = String(decoding: try await run(["merge", "--no-edit", ref.fullName], in: root),
                                    as: UTF8.self)
                return output.contains("Already up to date") ? .upToDate
                    : output.contains("Fast-forward") ? .fastForward : .merged
            } catch RemoteGitError.failed(let message) {
                // A conflicted merge exits 1 too; it differs in leaving unmerged paths.
                let unmerged = try await run(["diff", "--name-only", "--diff-filter=U", "-z"], in: root)
                let count = RemoteGitParser.nullSeparated(unmerged).count
                guard count > 0 else { throw RemoteGitError.failed(message) }
                return .conflicts(count)
            }
        }
    }
}

/// SwiftGitX has no merge, so this drives libgit2 directly on its own handle,
/// as `GitHubTransport` does, following `git merge`'s rules.
nonisolated enum GitMerge {
    static func merge(_ ref: GitBranchRef, root: URL, author: SourceControlIdentity?) throws -> GitMergeOutcome {
        try withRepository(at: root) { repository in
            guard git_repository_state(repository) == Int32(GIT_REPOSITORY_STATE_NONE.rawValue) else {
                throw GitRefActionError.operationInProgress
            }
            guard git_repository_head_detached(repository) == 0, git_repository_head_unborn(repository) == 0 else {
                throw GitRefActionError.noBranch
            }
            var head: OpaquePointer?
            try check(git_repository_head(&head, repository))
            defer { git_reference_free(head) }
            var headCommit: OpaquePointer?
            try check(git_reference_peel(&headCommit, head, GIT_OBJECT_COMMIT))
            defer { git_object_free(headCommit) }

            // `git merge` refuses staged changes, which would otherwise be
            // recorded in the merge commit along with the merge.
            var index: OpaquePointer?
            try check(git_repository_index(&index, repository))
            defer { git_index_free(index) }
            var headTree: OpaquePointer?
            try check(git_commit_tree(&headTree, headCommit))
            defer { git_tree_free(headTree) }
            var staged: OpaquePointer?
            try check(git_diff_tree_to_index(&staged, repository, headTree, index, nil))
            defer { git_diff_free(staged) }
            guard git_diff_num_deltas(staged) == 0 else { throw GitRefActionError.stagedChanges }

            var theirsReference: OpaquePointer?
            try check(git_reference_lookup(&theirsReference, repository, ref.fullName))
            defer { git_reference_free(theirsReference) }
            var theirs: OpaquePointer?
            try check(git_annotated_commit_from_ref(&theirs, repository, theirsReference))
            defer { git_annotated_commit_free(theirs) }
            var heads: [OpaquePointer?] = [theirs]

            var analysis = git_merge_analysis_t(0)
            var preference = git_merge_preference_t(0)
            try check(git_merge_analysis(&analysis, &preference, repository, &heads, 1))
            if analysis.rawValue & GIT_MERGE_ANALYSIS_UP_TO_DATE.rawValue != 0 { return .upToDate }

            if analysis.rawValue & GIT_MERGE_ANALYSIS_FASTFORWARD.rawValue != 0,
               preference.rawValue & GIT_MERGE_PREFERENCE_NO_FASTFORWARD.rawValue == 0 {
                let target = git_annotated_commit_id(theirs)
                var commit: OpaquePointer?
                try check(git_object_lookup(&commit, repository, target, GIT_OBJECT_COMMIT))
                defer { git_object_free(commit) }
                var options = git_checkout_options()
                try check(git_checkout_options_init(&options, UInt32(GIT_CHECKOUT_OPTIONS_VERSION)))
                options.checkout_strategy = GIT_CHECKOUT_SAFE.rawValue
                try check(git_checkout_tree(repository, commit, &options))
                var moved: OpaquePointer?
                try check(git_reference_set_target(&moved, head, target, "merge \(ref.name): Fast-forward"))
                git_reference_free(moved)
                return .fastForward
            }

            guard analysis.rawValue & GIT_MERGE_ANALYSIS_NORMAL.rawValue != 0 else {
                throw GitRefActionError.git("“\(ref.name)” can’t be merged into this branch.")
            }
            // Checked before the work tree changes, so no merge starts that
            // couldn't be committed.
            guard let author else { throw GitRefActionError.missingIdentity }
            // Defaults check out safely and fail, untouched, if the merge would
            // overwrite uncommitted changes.
            try check(git_merge(repository, &heads, 1, nil, nil))

            if git_index_has_conflicts(index) != 0 {
                // MERGE_HEAD and MERGE_MSG stay, so the next commit finishes it.
                var iterator: OpaquePointer?
                try check(git_index_conflict_iterator_new(&iterator, index))
                defer { git_index_conflict_iterator_free(iterator) }
                var ancestor: UnsafePointer<git_index_entry>?
                var ours: UnsafePointer<git_index_entry>?
                var theirsEntry: UnsafePointer<git_index_entry>?
                var count = 0
                while git_index_conflict_next(&ancestor, &ours, &theirsEntry, iterator) == 0 { count += 1 }
                return .conflicts(count)
            }

            var treeID = git_oid()
            try check(git_index_write_tree(&treeID, index))
            var tree: OpaquePointer?
            try check(git_tree_lookup(&tree, repository, &treeID))
            defer { git_tree_free(tree) }
            var theirCommit: OpaquePointer?
            try check(git_commit_lookup(&theirCommit, repository, git_annotated_commit_id(theirs)))
            defer { git_commit_free(theirCommit) }
            var signature: UnsafeMutablePointer<git_signature>?
            try check(git_signature_now(&signature, author.name, author.email))
            defer { git_signature_free(signature) }
            // libgit2 wrote Git's own wording to MERGE_MSG.
            var buffer = git_buf()
            defer { git_buf_dispose(&buffer) }
            let message = git_repository_message(&buffer, repository) >= 0 && buffer.ptr != nil
                ? String(cString: buffer.ptr).trimmingCharacters(in: .whitespacesAndNewlines)
                : "Merge branch '\(ref.name)'"
            var parents: [OpaquePointer?] = [headCommit, theirCommit]
            var commitID = git_oid()
            try check(git_commit_create(&commitID, repository, "HEAD", signature, signature, nil, message,
                                        tree, 2, &parents))
            try check(git_repository_state_cleanup(repository))
            return .merged
        }
    }

    /// SwiftGitX's commit records MERGE_HEAD as a parent but leaves it behind,
    /// which would make every later commit a merge too. `git commit` clears
    /// this state; so does this, after the app commits.
    static func finishCommit(root: URL) throws {
        try withRepository(at: root) { repository in
            let finished: [git_repository_state_t] = [
                GIT_REPOSITORY_STATE_MERGE, GIT_REPOSITORY_STATE_REVERT, GIT_REPOSITORY_STATE_CHERRYPICK,
            ]
            let state = git_repository_state(repository)
            guard finished.contains(where: { Int32($0.rawValue) == state }) else { return }
            try check(git_repository_state_cleanup(repository))
        }
    }

    private static func withRepository<T>(at root: URL, _ body: (OpaquePointer) throws -> T) throws -> T {
        guard git_libgit2_init() >= 0 else { throw GitRefActionError.git("libgit2 failed to start.") }
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        try check(git_repository_open(&repository, root.path))
        guard let repository else { throw GitRefActionError.git("The repository couldn’t be opened.") }
        defer { git_repository_free(repository) }
        return try body(repository)
    }

    private static func check(_ status: Int32) throws {
        guard status < 0 else { return }
        let message = git_error_last().flatMap { $0.pointee.message.map { String(cString: $0) } }
        throw GitRefActionError.git(message ?? "libgit2 error \(status).")
    }
}
