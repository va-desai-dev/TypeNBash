import Foundation
import SwiftUI

/// Source control for an SSH workspace. libgit2 only reaches this Mac's disk,
/// so a remote repository is driven through the host's own `git`, over the
/// workspace's existing control connection, and its porcelain output is parsed
/// into the same snapshot and comparison types the local path produces.
///
/// Fetch and push use the host's own credentials (its SSH keys or credential
/// helper) unless the host is opted in to the TypeNBash GitHub sign-in; see
/// `run(_:in:toleratedStatus:lending:)` for how that sign-in is offered.
@MainActor
struct RemoteGit {
    let backend: SSHWorkspaceBackend

    /// The host this repository lives on, which is what the GitHub opt-in is
    /// remembered against.
    var profileID: UUID? {
        guard case .ssh(let profile) = backend.location else { return nil }
        return profile.id
    }

    /// Exit statuses up to `toleratedStatus` count as success, because
    /// `diff --no-index` exits 1 whenever the files differ.
    ///
    /// Prompts are disabled because there is no terminal to answer them, and
    /// optional locks are off so a refresh never contends with the user's own
    /// `git` in the console. Pathspecs are literal so a file named `*.py` or
    /// `:x` means exactly that file.
    ///
    /// A lent credential answers GitHub the way VS Code's remote Git does: the
    /// token travels on the SSH channel's stdin for this one command, lives
    /// only in that command's environment, and is handed to Git by an inline
    /// credential helper that answers `https://github.com` and nothing else.
    /// The host's configured helpers are cleared for the command so none of
    /// them — `store` in particular — can write the token to the host's disk,
    /// and redirects are refused so it can't be forwarded elsewhere.
    func run(_ arguments: [String], in directory: URL, toleratedStatus: Int32 = 0,
             lending credential: GitHubCredential? = nil) async throws -> Data {
        let script = #"""
        dir=$1; ok=$2; lend=$3; shift 3
        set -- -c core.quotePath=false --literal-pathspecs -C "$dir" "$@"
        if [ "$lend" = 1 ]; then
            IFS= read -r TNB_GH_USER; IFS= read -r TNB_GH_TOKEN
            export TNB_GH_USER TNB_GH_TOKEN
            helper='!f() { [ "$1" = get ] || return 0; p=; h=; while IFS== read -r k v; do case "$k" in protocol) p=$v;; host) h=$v;; esac; done; [ "$p" = https ] || return 0; case "$h" in github.com|github.com:443) printf "username=%s\npassword=%s\n" "$TNB_GH_USER" "$TNB_GH_TOKEN";; esac; }; f'
            set -- -c credential.helper= -c "credential.helper=$helper" -c http.followRedirects=false "$@"
        fi
        GIT_TERMINAL_PROMPT=0 GIT_OPTIONAL_LOCKS=0 git "$@"
        status=$?
        [ "$status" -le "$ok" ] && exit 0
        exit "$status"
        """#
        do {
            return try await backend.execute(
                program: "sh",
                arguments: ["-c", script, "sh", directory.path, String(toleratedStatus),
                            credential == nil ? "0" : "1"] + arguments,
                standardInput: credential.map { Data("\($0.login)\n\($0.token)\n".utf8) }
            ).standardOutput
        } catch SSHConnectionError.commandFailed(status: 127, message: _) {
            throw RemoteGitError.missing
        } catch SSHConnectionError.commandFailed(status: _, message: let message) {
            throw RemoteGitError.failed(message)
        }
    }

    func repositoryRoot(in directory: URL) async throws -> URL {
        let output: Data
        do {
            output = try await run(["rev-parse", "--show-toplevel"], in: directory)
        } catch RemoteGitError.failed {
            throw RemoteGitError.noRepository
        }
        let path = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard path.hasPrefix("/") else { throw RemoteGitError.noRepository }
        return URL(filePath: path, directoryHint: .isDirectory)
    }

    // MARK: Source control

    /// `lendsGitHubSignIn` is the host's opt-in to the TypeNBash GitHub account.
    func perform(_ action: SourceControlAction, in directory: URL,
                 lendsGitHubSignIn: Bool = false) async throws -> SourceControlSnapshot {
        let root = try await repositoryRoot(in: directory)
        switch action {
        case .refresh: break
        case .stage(let path): _ = try await run(["add", "--", path], in: root)
        case .unstage(let path): _ = try await run(["restore", "--staged", "--", path], in: root)
        case .commit(let message):
            guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RemoteGitError.emptyMessage
            }
            _ = try await run(["commit", "-m", message], in: root)
        case .fetch(let name):
            try Self.validateRemoteName(name)
            let credential = lendsGitHubSignIn
                ? try await lendableCredential(remote: name, pushing: false, in: root) : nil
            try await transfer(["fetch", name], in: root, lending: credential)
        case .push(let name):
            try Self.validateRemoteName(name)
            // Same shape as the local push: an explicit, non-forced refspec for
            // the current branch only, whatever the remote's configuration says.
            guard (try? await run(["rev-parse", "--verify", "-q", "HEAD"], in: root)) != nil,
                  let output = try? await run(["symbolic-ref", "-q", "HEAD"], in: root) else {
                throw GitPushError.noBranch
            }
            let branch = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .newlines)
            guard branch.hasPrefix("refs/heads/") else { throw GitPushError.noBranch }
            let credential = lendsGitHubSignIn
                ? try await lendableCredential(remote: name, pushing: true, in: root) : nil
            try await transfer(["push", name, "\(branch):\(branch)"], in: root, lending: credential)
        }
        let status = try await run(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"], in: root)
        let remotes = try await run(["remote"], in: root)
        return await RemoteGitParser.snapshot(root: root, status: status, remotes: remotes)
    }

    /// The TypeNBash GitHub sign-in, if the remote is one it may be offered to:
    /// the same HTTPS-on-github.com rule the local transport applies. Any other
    /// remote — including `git@github.com:` over SSH — keeps the host's own
    /// credentials, as does a Mac that isn't signed in.
    private func lendableCredential(remote name: String, pushing: Bool, in root: URL) async throws -> GitHubCredential? {
        let output = try await run(["remote", "get-url"] + (pushing ? ["--push"] : []) + [name], in: root)
        let address = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: address), GitHubCredentialContext.accepts(url) else { return nil }
        return try await GitHubAuthenticationService.shared.validCredential()
    }

    /// Fetch or push, with a refused login reported as one: "sign in again"
    /// when it was TypeNBash's sign-in, or a pointer to the opt-in when it was
    /// the host's own credentials.
    private func transfer(_ arguments: [String], in root: URL, lending credential: GitHubCredential?) async throws {
        do {
            _ = try await run(arguments, in: root, lending: credential)
        } catch RemoteGitError.failed(let message) where Self.isAuthenticationFailure(message) {
            throw credential == nil ? RemoteGitError.hostCredentialsRejected : GitHubDeviceFlowError.signInAgain
        }
    }

    private static func isAuthenticationFailure(_ message: String) -> Bool {
        ["Authentication failed", "Invalid username or password", "could not read Username",
         "Permission denied (publickey"].contains { message.contains($0) }
    }

    private static func validateRemoteName(_ name: String) throws {
        // Remote names come from `git remote`, but never let one read as an option.
        guard !name.isEmpty, !name.hasPrefix("-") else { throw RemoteGitError.failed("Choose a remote.") }
    }

    // MARK: Comparison

    func diff(directory: URL, scope: GitDiffScope, selectedPath: String?) async throws -> GitDiffResult {
        let root = try await repositoryRoot(in: directory)
        var comparison: [String] = []
        if scope == .staged { comparison.append("--cached") }
        if scope != .unstaged {
            // Before the first commit there is no HEAD, so compare against the
            // empty tree — hashed on the host so SHA-256 repositories work too.
            if (try? await run(["rev-parse", "--verify", "-q", "HEAD^{tree}"], in: root)) != nil {
                comparison.append("HEAD")
            } else {
                let empty = try await run(["hash-object", "-t", "tree", "/dev/null"], in: root)
                comparison.append(String(decoding: empty, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
            }
        }
        let options = ["--no-color", "--no-ext-diff", "--no-textconv", "-M"]

        let names = try await run(["diff"] + comparison + options + ["--name-status", "-z"], in: root)
        // `git diff` never lists untracked files; libgit2's comparison does,
        // for every scope that reaches the working tree.
        let untracked = scope == .staged ? Data()
            : try await run(["ls-files", "--others", "--exclude-standard", "-z"], in: root)
        let files = await RemoteGitParser.files(nameStatus: names, untracked: untracked)

        // Totals for the whole comparison. Untracked files aren't in `git
        // diff`, so their lines are counted with `grep -c`: an empty pattern
        // matches every line, `-I` skips binaries, and exit 1 just means none
        // of them had any lines.
        let numstat = try await run(["diff"] + comparison + options + ["--numstat", "-z"], in: root)
        var stats = await RemoteGitParser.stats(numstat: numstat)
        let untrackedPaths = RemoteGitParser.nullSeparated(untracked)
        if !untrackedPaths.isEmpty {
            let counts = try await run(["grep", "--untracked", "-I", "-c", "-z", "-e", "", "--"] + untrackedPaths,
                                       in: root, toleratedStatus: 1)
            stats.insertions += await RemoteGitParser.lineCount(grepCounts: counts)
        }

        let relativeSelection = selectedPath.map { path in
            let prefix = root.path + "/"
            return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
        }
        guard let file = files.first(where: { $0.path == relativeSelection }) ?? files.first else {
            return GitDiffResult(files: files, selectedPath: nil, rows: [], message: "No changes in this comparison.",
                                 stats: stats)
        }

        let patch: Data
        if file.status == .added, untrackedPaths.contains(file.path) {
            patch = try await run(
                ["diff", "--no-index"] + options + ["--", "/dev/null", file.path],
                in: root, toleratedStatus: 1
            )
        } else {
            let paths = file.oldPath == file.path ? [file.path] : [file.oldPath, file.path]
            patch = try await run(["diff"] + comparison + options + ["-U3", "--"] + paths, in: root)
        }
        let parsed = await RemoteGitParser.rows(fromPatch: patch)
        if parsed.binary {
            return GitDiffResult(files: files, selectedPath: file.path, rows: [],
                                 message: "Binary file. No text comparison is available.", stats: stats)
        }
        return GitDiffResult(
            files: files, selectedPath: file.path, rows: parsed.rows,
            message: parsed.truncated ? "Preview limited to 20,000 lines."
                : parsed.rows.isEmpty ? "No textual changes (file metadata or conflict)." : nil,
            stats: stats
        )
    }
}

/// Pure parsers for git's machine-readable output, run off the main actor
/// because a large diff is a lot of text.
nonisolated enum RemoteGitParser {
    static func nullSeparated(_ data: Data) -> [String] {
        String(decoding: data, as: UTF8.self)
            .split(separator: "\0")
            .map(String.init)
    }

    /// Sums `git diff --numstat -z`. Each record is `added\tdeleted\tpath\0`,
    /// or `added\tdeleted\t\0old\0new\0` for a rename; binaries report `-`.
    @concurrent
    static func stats(numstat: Data) async -> GitDiffStats {
        var stats = GitDiffStats()
        var fields = nullSeparated(numstat)[...]
        while let record = fields.popFirst() {
            let columns = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard columns.count == 3 else { continue }
            stats.insertions += Int(columns[0]) ?? 0
            stats.deletions += Int(columns[1]) ?? 0
            // An empty path column means the two paths follow as fields.
            if columns[2].isEmpty { fields = fields.dropFirst(2) }
        }
        return stats
    }

    /// Sums `git grep -c -z`, which prints `path\0count\n` per file.
    @concurrent
    static func lineCount(grepCounts: Data) async -> Int {
        nullSeparated(grepCounts).dropFirst().reduce(0) { total, field in
            total + (Int(field.prefix { $0 != "\n" }) ?? 0)
        }
    }

    /// Reads `git status --porcelain=v2 --branch -z`.
    @concurrent
    static func snapshot(root: URL, status: Data, remotes: Data) async -> SourceControlSnapshot {
        var head = ""
        var oid = ""
        var changes: [SourceControlChange] = []
        var records = String(decoding: status, as: UTF8.self).split(separator: "\0")[...]
        while let record = records.popFirst() {
            if record.hasPrefix("# branch.head ") {
                head = String(record.dropFirst("# branch.head ".count))
                continue
            }
            if record.hasPrefix("# branch.oid ") {
                oid = String(record.dropFirst("# branch.oid ".count))
                continue
            }
            // Ordinary, renamed and unmerged entries carry a fixed number of
            // space-separated fields before the path, which may itself contain spaces.
            let fieldCount: Int
            switch record.first {
            case "1": fieldCount = 8
            case "2": fieldCount = 9
            case "u": fieldCount = 10
            case "?":
                changes.append(SourceControlChange(path: String(record.dropFirst(2)),
                                                   staged: false, unstaged: true, conflicted: false))
                continue
            default: continue
            }
            let fields = record.split(separator: " ", maxSplits: fieldCount, omittingEmptySubsequences: false)
            // A rename's original path follows as its own record.
            if record.first == "2" { _ = records.popFirst() }
            guard fields.count == fieldCount + 1, fields[1].count == 2 else { continue }
            let xy = Array(fields[1])
            changes.append(SourceControlChange(
                path: String(fields[fieldCount]),
                staged: xy[0] != ".",
                unstaged: xy[1] != ".",
                conflicted: record.first == "u"
            ))
        }
        let unborn = oid == "(initial)"
        let detached = head == "(detached)"
        return SourceControlSnapshot(
            root: root,
            branch: unborn ? "No commits yet" : detached ? "Detached at \(oid.prefix(7))" : head,
            detached: detached,
            unborn: unborn,
            changes: changes.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending },
            remotes: String(decoding: remotes, as: UTF8.self)
                .split(whereSeparator: \.isNewline).map(String.init).sorted()
        )
    }

    /// Reads `git diff --name-status -z`, plus untracked paths from `ls-files -z`.
    @concurrent
    static func files(nameStatus: Data, untracked: Data) async -> [GitDiffFile] {
        var files: [GitDiffFile] = []
        var seen: Set<String> = []
        var fields = nullSeparated(nameStatus)[...]
        while let code = fields.popFirst(), let first = fields.popFirst() {
            var oldPath = first
            var path = first
            // Renames and copies name both sides.
            if code.hasPrefix("R") || code.hasPrefix("C"), let second = fields.popFirst() {
                path = second
            } else {
                oldPath = path
            }
            let status: GitDiffStatus = switch code.first {
            case "A": .added
            case "D": .deleted
            case "R": .renamed
            case "U": .conflicted
            default: .modified
            }
            // An unmerged path can be reported once per stage.
            guard seen.insert(path).inserted else { continue }
            files.append(GitDiffFile(path: path, oldPath: oldPath, status: status))
        }
        for path in nullSeparated(untracked) where seen.insert(path).inserted {
            files.append(GitDiffFile(path: path, oldPath: path, status: .added))
        }
        return files.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    /// Turns one file's unified diff into the same side-by-side rows the
    /// libgit2 comparison builds: runs of removals, then additions, between
    /// context lines.
    @concurrent
    static func rows(fromPatch data: Data) async -> (rows: [GitDiffRow], truncated: Bool, binary: Bool) {
        var rows: [GitDiffRow] = []
        var removed: [GitDiffLine] = []
        var added: [GitDiffLine] = []
        func flush() {
            for line in removed { rows.append(GitDiffRow(id: rows.count, left: line, right: nil)) }
            for line in added { rows.append(GitDiffRow(id: rows.count, left: nil, right: line)) }
            removed.removeAll(keepingCapacity: true)
            added.removeAll(keepingCapacity: true)
        }
        var oldLine = 0
        var newLine = 0
        var inHunk = false
        var truncated = false
        var binary = false
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("@@ ") {
                flush()
                // "@@ -a[,b] +c[,d] @@ optional function context"
                let ranges = line.split(separator: " ").dropFirst().prefix(2)
                func range(_ token: Substring?) -> (start: Int, count: Int) {
                    let parts = (token?.dropFirst() ?? "").split(separator: ",")
                    return (Int(parts.first ?? "") ?? 0, parts.count > 1 ? Int(parts[1]) ?? 0 : 1)
                }
                let old = range(ranges.first)
                let new = range(ranges.dropFirst().first)
                oldLine = old.start
                newLine = new.start
                inHunk = true
                let label = GitDiffLine(number: nil, text: "@@ −\(old.start),\(old.count) +\(new.start),\(new.count) @@", changed: false)
                rows.append(GitDiffRow(id: rows.count, left: label, right: label, isHeader: true))
                continue
            }
            guard inHunk else {
                if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { binary = true }
                continue
            }
            if rows.count + removed.count + added.count >= 20_000 { truncated = true; break }
            var text = String(line.dropFirst().prefix(10_000))
            if text.hasSuffix("\r") { text.removeLast() }
            if line.count > 10_001 { text += " … [line truncated]" }
            switch line.first {
            case "-":
                removed.append(GitDiffLine(number: oldLine, text: text, changed: true))
                oldLine += 1
            case "+":
                added.append(GitDiffLine(number: newLine, text: text, changed: true))
                newLine += 1
            case " ":
                flush()
                rows.append(GitDiffRow(id: rows.count,
                                       left: GitDiffLine(number: oldLine, text: text, changed: false),
                                       right: GitDiffLine(number: newLine, text: text, changed: false)))
                oldLine += 1
                newLine += 1
            case "\\":
                flush()
                let note = GitDiffLine(number: nil, text: "No newline at end of file", changed: false)
                rows.append(GitDiffRow(id: rows.count, left: note, right: note, isHeader: true))
            default:
                inHunk = false
            }
        }
        flush()
        return (rows, truncated, binary)
    }
}

nonisolated enum RemoteGitError: LocalizedError {
    case missing, noRepository, emptyMessage, hostCredentialsRejected, failed(String)
    var errorDescription: String? {
        switch self {
        case .hostCredentialsRejected:
            "GitHub didn’t accept this host’s own login. Turn on “Use my GitHub sign-in on this host” above to use your TypeNBash sign-in instead."
        case .missing: "Git is not installed on the remote host, or is not on its PATH."
        case .noRepository: "This remote folder is not inside a Git repository."
        case .emptyMessage: "Enter a commit message."
        case .failed(let message): message.isEmpty ? "The remote Git command failed." : message
        }
    }
}
