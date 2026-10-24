import Foundation
import Observation
import SwiftGitX

/// The repository's references, as the Repositories tab lists them. Both the
/// local (libgit2) and SSH (`git` porcelain) paths reduce their output to the
/// same plain names, so the grouping below is shared.
nonisolated struct GitRefSnapshot: Equatable, Sendable {
    struct Remote: Equatable, Sendable {
        let name: String
        let url: String
        /// Branch names without the `remote/` prefix.
        let branches: [String]
    }

    /// The checked-out branch; nil when HEAD is detached or unborn.
    var current: String?
    var branches: [String] = []
    /// Branches checked out most recently first, from HEAD's reflog.
    var recents: [String] = []
    var tags: [String] = []
    /// `stash@{n}` messages, newest first.
    var stashes: [String] = []
    var remotes: [Remote] = []

    static let recentLimit = 5

    /// - Parameters:
    ///   - remoteBranches: Short names such as `origin/main`.
    ///   - checkouts: HEAD's reflog subjects, newest first.
    init(current: String?, branches: [String], remoteBranches: [String], tags: [String],
         stashes: [String], remotes: [(name: String, url: String)], checkouts: [String]) {
        self.current = current
        self.branches = branches.sorted(by: Self.ordered)
        self.tags = tags.sorted(by: Self.ordered)
        self.stashes = stashes
        self.remotes = remotes.sorted { Self.ordered($0.name, $1.name) }.map { remote in
            let prefix = remote.name + "/"
            return Remote(name: remote.name, url: remote.url, branches: remoteBranches
                .filter { $0.hasPrefix(prefix) && $0 != prefix + "HEAD" }
                .map { String($0.dropFirst(prefix.count)) }
                .sorted(by: Self.ordered))
        }
        // `checkout: moving from A to B` — B was checked out after A, so
        // newest first is B, then A. Counting A too keeps a branch that was
        // only ever left, like the one `git init` started on. Detached
        // checkouts name a commit, which `branches` filters out along with
        // branches deleted since. Branch names can't contain spaces.
        let local = Set(branches)
        var seen = Set<String>()
        for subject in checkouts where recents.count < Self.recentLimit {
            guard let to = subject.range(of: " to ", options: .backwards),
                  let from = subject.range(of: "moving from ") else { continue }
            for name in [String(subject[to.upperBound...]), String(subject[from.upperBound..<to.lowerBound])]
            where recents.count < Self.recentLimit && local.contains(name) && seen.insert(name).inserted {
                recents.append(name)
            }
        }
    }

    static func ordered(_ lhs: String, _ rhs: String) -> Bool {
        lhs.localizedStandardCompare(rhs) == .orderedAscending
    }
}

/// A row in the Repositories outline.
nonisolated struct GitRefNode: Identifiable, Hashable, Sendable {
    enum Kind: Hashable, Sendable {
        case folder, branch, remoteBranch, tag, stash, remote
    }

    let id: String
    let title: String
    let kind: Kind
    var isCurrent = false
    /// Shown as the row's tooltip: a remote's URL or a stash's full message.
    var detail: String?
    /// Set on branch rows, local or remote, which the context menu acts on.
    var ref: GitBranchRef?
    var children: [GitRefNode] = []

    var icon: String {
        switch kind {
        case .folder: "folder.fill"
        case .branch, .remoteBranch: "arrow.trianglehead.branch"
        case .tag: "tag"
        case .stash: "tray.full"
        case .remote: "server.rack"
        }
    }

    /// Splits slash-separated names into folders the way Xcode does, so
    /// `claude/festive-ramanujan` sits in a `claude` folder. Folders and
    /// leaves sort together by title.
    /// - Parameter remote: The remote that `names` belong to, for remote branches.
    static func outline(_ names: [String], kind: Kind, idPrefix: String,
                        current: String? = nil, remote: String? = nil) -> [GitRefNode] {
        grouped(names.map { ($0[...], $0) }, kind: kind, idPrefix: idPrefix, folderPath: "",
                current: current, remote: remote)
    }

    private static func grouped(_ refs: [(rest: Substring, name: String)], kind: Kind, idPrefix: String,
                                folderPath: String, current: String?, remote: String?) -> [GitRefNode] {
        var nodes: [GitRefNode] = []
        var folders: [String: [(rest: Substring, name: String)]] = [:]
        for ref in refs {
            if let slash = ref.rest.firstIndex(of: "/") {
                folders[String(ref.rest[..<slash]), default: []]
                    .append((ref.rest[ref.rest.index(after: slash)...], ref.name))
            } else {
                nodes.append(GitRefNode(id: idPrefix + ref.name, title: String(ref.rest), kind: kind,
                                        isCurrent: ref.name == current,
                                        ref: kind == .tag ? nil : GitBranchRef(branch: ref.name, remote: remote)))
            }
        }
        for (folder, contents) in folders {
            let path = folderPath + folder + "/"
            nodes.append(GitRefNode(id: idPrefix + path, title: folder, kind: .folder,
                                    children: grouped(contents, kind: kind, idPrefix: idPrefix,
                                                      folderPath: path, current: current, remote: remote)))
        }
        return nodes.sorted { GitRefSnapshot.ordered($0.title, $1.title) }
    }
}

extension SourceControlService {
    func refs(in directory: URL) throws -> GitRefSnapshot {
        let root = try Self.repositoryRoot(in: directory)
        let repository = try Repository(at: root, createIfNotExists: false)
        // Unborn and detached HEADs both throw here; neither has a current branch.
        let current = repository.isHEADDetached ? nil : try? repository.branch.current.name
        // libgit2 has no reflog API in SwiftGitX, but the log is a plain file:
        // `old new committer <email> time zone\tmessage` per line, oldest first.
        // `path` is the worktree's own git directory, so this is its HEAD.
        let reflog = (try? String(contentsOf: repository.path.appending(path: "logs/HEAD"), encoding: .utf8)) ?? ""
        let checkouts = reflog.split(whereSeparator: \.isNewline).reversed().compactMap { line -> String? in
            guard let tab = line.firstIndex(of: "\t") else { return nil }
            let message = line[line.index(after: tab)...]
            return message.hasPrefix("checkout: ") ? String(message) : nil
        }
        return GitRefSnapshot(
            current: current,
            branches: try repository.branch.list(.local).map(\.name),
            remoteBranches: try repository.branch.list(.remote).map(\.name),
            tags: try repository.tag.list().map(\.name),
            stashes: try repository.stash.list().sorted { $0.index < $1.index }.map(\.message),
            remotes: try repository.remote.list().map { (name: $0.name, url: $0.url.absoluteString) },
            checkouts: checkouts
        )
    }
}

extension RemoteGit {
    func refs(in directory: URL) async throws -> GitRefSnapshot {
        let root = try await repositoryRoot(in: directory)
        func lines(_ arguments: [String], toleratedStatus: Int32 = 0) async throws -> [String] {
            String(decoding: try await run(arguments, in: root, toleratedStatus: toleratedStatus), as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init)
        }
        // Ref names can't contain newlines, so line-separated output is safe.
        let refs = try await lines(["for-each-ref", "--format=%(refname)", "refs/heads", "refs/remotes", "refs/tags"])
        func names(under prefix: String) -> [String] {
            refs.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
        }
        // `symbolic-ref -q` exits 1 for a detached HEAD.
        let current = try await lines(["symbolic-ref", "-q", "--short", "HEAD"], toleratedStatus: 1).first
        // An unborn HEAD has no reflog yet.
        let checkouts = (try? await lines(["reflog", "show", "--format=%gs", "-n", "500", "HEAD"])) ?? []
        // `name\turl (fetch)` and `name\turl (push)` per remote.
        let remotes = try await lines(["remote", "-v"]).compactMap { line -> (name: String, url: String)? in
            let fields = line.split(separator: "\t", maxSplits: 1)
            guard fields.count == 2, fields[1].hasSuffix(" (fetch)") else { return nil }
            return (String(fields[0]), String(fields[1].dropLast(" (fetch)".count)))
        }
        return GitRefSnapshot(
            current: current,
            branches: names(under: "refs/heads/"),
            remoteBranches: names(under: "refs/remotes/"),
            tags: names(under: "refs/tags/"),
            stashes: try await lines(["stash", "list", "--format=%gs"]),
            remotes: remotes,
            checkouts: checkouts.filter { $0.hasPrefix("checkout: ") }
        )
    }
}

/// Backs the Repositories tab. It outlives the tab's list, so a trip to
/// Changes and back keeps what was expanded and selected.
@MainActor
@Observable
final class GitRefsModel {
    struct Notice: Equatable {
        let title: String
        let message: String
    }

    let directory: URL
    /// Set for an SSH workspace, whose repository lives on the host.
    let remote: RemoteGit?
    /// The editor's files, which a switch or merge rewrites underneath it.
    let files: FileBrowserModel
    private(set) var snapshot: GitRefSnapshot?
    private(set) var errorMessage: String?
    private(set) var isLoading = false
    private(set) var isBusy = false
    /// The outcome of a branch action, shown as an alert.
    var notice: Notice?
    var selection: String?
    /// Sections and folders start expanded, as in Xcode, so this tracks the
    /// ones the user closed.
    var collapsed: Set<String> = []
    private let service = SourceControlService()
    private var generation = 0

    init(directory: URL, remote: RemoteGit? = nil, files: FileBrowserModel) {
        self.directory = directory
        self.remote = remote
        self.files = files
    }

    /// Why branch actions are unavailable, or nil when they can run. Unsaved
    /// edits would otherwise be saved back over whatever the action wrote.
    var actionBlocker: String? {
        if isBusy { return "Another branch action is running." }
        if files.hasUnsavedChanges { return "Save or discard the open file’s edits first." }
        return nil
    }

    func perform(_ action: GitRefAction) async {
        guard actionBlocker == nil else { return }
        isBusy = true
        let target = snapshot?.current ?? "HEAD"
        do {
            let outcome = if let remote {
                try await remote.perform(action, in: directory)
            } else {
                try await service.perform(action, in: directory,
                                          defaultIdentity: SourceControlIdentitySettings.shared.identity)
            }
            if case .merge(let ref) = action, let outcome {
                notice = Notice(title: action.title, message: outcome.message(merging: ref.name, into: target))
            }
        } catch {
            // SwiftGitXError doesn't conform to LocalizedError.
            notice = Notice(title: "\(action.title) Failed",
                            message: (error as? SwiftGitXError).map { "Git: " + $0.message } ?? error.localizedDescription)
        }
        isBusy = false
        // Even a failed action may have moved HEAD or rewritten files, so
        // everything that mirrors the work tree reloads either way: the
        // editor's gutter, the Changes list and the sidebar footer.
        NotificationCenter.default.post(name: .editorGitBaselineDidChange, object: nil)
        NotificationCenter.default.post(name: .gitRepositoryDidChange, object: self)
        files.refresh()
        await files.reloadSelectedFile()
        await refresh()
    }

    func refresh() async {
        generation &+= 1
        let request = generation
        isLoading = true
        errorMessage = nil
        do {
            let loaded = if let remote {
                try await remote.refs(in: directory)
            } else {
                try await service.refs(in: directory)
            }
            guard request == generation else { return }
            snapshot = loaded
        } catch {
            guard request == generation else { return }
            snapshot = nil
            // SwiftGitXError doesn't conform to LocalizedError.
            errorMessage = (error as? SwiftGitXError).map { "Git: " + $0.message } ?? error.localizedDescription
        }
        isLoading = false
    }

    func nodes(for section: RepoDisclosureItems) -> [GitRefNode] {
        guard let snapshot else { return [] }
        switch section {
        case .branches:
            return GitRefNode.outline(snapshot.branches, kind: .branch, idPrefix: "refs/heads/",
                                      current: snapshot.current)
        case .recents:
            // Flat and in checkout order, not alphabetical.
            return snapshot.recents.map {
                GitRefNode(id: "recent:" + $0, title: $0, kind: .branch, isCurrent: $0 == snapshot.current,
                           ref: GitBranchRef(branch: $0))
            }
        case .tags:
            return GitRefNode.outline(snapshot.tags, kind: .tag, idPrefix: "refs/tags/")
        case .stashes:
            return snapshot.stashes.enumerated().map { index, message in
                GitRefNode(id: "stash@{\(index)}", title: message, kind: .stash, detail: "stash@{\(index)}: \(message)")
            }
        case .remotes:
            return snapshot.remotes.map { remote in
                GitRefNode(id: "remote:" + remote.name, title: remote.name, kind: .remote, detail: remote.url,
                           children: GitRefNode.outline(remote.branches, kind: .remoteBranch,
                                                        idPrefix: "refs/remotes/\(remote.name)/",
                                                        remote: remote.name))
            }
        }
    }
}
