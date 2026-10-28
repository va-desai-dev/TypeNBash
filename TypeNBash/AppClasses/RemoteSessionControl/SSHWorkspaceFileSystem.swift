import Foundation

final class SSHWorkspaceFileSystem: WorkspaceFileSystem {
    let homeDirectory: URL
    let folderChanges: AsyncStream<URL>

    private let connection: OpenSSHConnection
    private let changes: AsyncStream<URL>.Continuation
    /// The newest launch. Nil or stopped means each operation runs its script
    /// over its own ssh client until a relaunch succeeds.
    private var helper: Task<SSHRemoteHelper?, Never>?
    private var lastLaunch = ContinuousClock.now
    private var watchedFolders: [URL] = []

    /// A host where the helper keeps dying falls back instead of relaunching on every call.
    private static let relaunchInterval = Duration.seconds(30)
    private static let scripts = Dictionary(uniqueKeysWithValues: Script.allCases.map { ($0.rawValue, $0.source) })

    /// The scripts the helper runs by name; each also runs alone as `python3 -c`.
    private enum Script: String, CaseIterable {
        case list, read, write, createFile, mkdir, remove, move, search, editorGitBaseline, find, agent

        var source: String {
            switch self {
                case .list: SSHWorkspaceFileSystem.listScript
                case .read: SSHWorkspaceFileSystem.readScript
                case .write: SSHWorkspaceFileSystem.writeScript
                case .createFile: SSHWorkspaceFileSystem.createFileScript
                case .mkdir: SSHWorkspaceFileSystem.mkdirScript
                case .remove: SSHWorkspaceFileSystem.removeScript
                case .move: SSHWorkspaceFileSystem.moveScript
                case .search: ProjectSearchFileAccess.remoteScript
                case .editorGitBaseline: RemoteGit.editorBaselineScript
                case .find: SSHWorkspaceFileSystem.findScript
                case .agent: AgentRemoteWorkspaceAccess.remoteScript
            }
        }
    }

    init(connection: OpenSSHConnection, homeDirectory: URL) {
        self.connection = connection
        self.homeDirectory = homeDirectory
        (folderChanges, changes) = AsyncStream<URL>.makeStream()
        launchHelper()
    }

    deinit {
        changes.finish()
    }

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry] {
        let output = try await run(.list, [directory.path, includingHiddenFiles ? "1" : "0"])
        let records: [RemoteEntry]
        do {
            records = try JSONDecoder().decode([RemoteEntry].self, from: output)
        } catch {
            throw WorkspaceFileSystemError.invalidResponse(error.localizedDescription)
        }
        return records.map { record in
            WorkspaceFileEntry(
                url: directory.appendingPathComponent(record.name, isDirectory: record.directory),
                isDirectory: record.directory,
                byteCount: record.size,
                modificationDate: record.mtime.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    // Reads at most `maximumByteCount` bytes (a prefix), so a large remote file
    // previews the same way a local one does.
    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        try await run(.read, [url.path, String(maximumByteCount)])
    }

    func searchEntries(at directory: URL, root: URL) async throws -> [WorkspaceFileEntry] {
        try JSONDecoder().decode([RemoteEntry].self, from: await run(.search, ["list", root.path, directory.path])).map {
            WorkspaceFileEntry(url: directory.appendingPathComponent($0.name), isDirectory: $0.directory, byteCount: $0.size)
        }
    }

    func readSearchFile(at url: URL, root: URL, limit: Int) async throws -> Data {
        try await run(.search, ["read", root.path, url.path, String(limit)])
    }

    func replaceSearchFile(at url: URL, root: URL, expected: Data, replacement: Data) async throws {
        let input = try JSONEncoder().encode(["expected": expected, "replacement": replacement])
        _ = try await run(.search, ["replace", root.path, url.path, String(expected.count)], input: input)
    }

    func writeFile(_ data: Data, to url: URL) async throws {
        _ = try await run(.write, [url.path], input: data)
    }

    func editorGitBaseline(at url: URL) async throws -> String? {
        try JSONDecoder().decode(String?.self, from: await run(.editorGitBaseline, [url.path]))
    }

    func findFiles(named query: String, under root: URL, includingHiddenFiles: Bool, limit: Int) async throws -> [WorkspaceFileEntry] {
        let output = try await run(.find, [root.path, query, includingHiddenFiles ? "1" : "0", String(limit)])
        return try JSONDecoder().decode([RemoteEntry].self, from: output).map { record in
            WorkspaceFileEntry(
                url: root.appendingPathComponent(record.name, isDirectory: record.directory),
                isDirectory: record.directory,
                byteCount: record.size,
                modificationDate: record.mtime.map(Date.init(timeIntervalSince1970:))
            )
        }
    }

    /// Agent workspace tools; `AgentRemoteWorkspaceAccess` owns the arguments.
    func agentWorkspace(_ arguments: [String], input: Data? = nil) async throws -> Data {
        try await run(.agent, arguments, input: input)
    }

    func createFile(_ data: Data, at url: URL) async throws {
        _ = try await run(.createFile, [url.path], input: data)
    }

    // One level only, like local. An existing name raises, which fails the request.
    func createDirectory(at url: URL) async throws {
        _ = try await run(.mkdir, [url.path])
    }

    /// The host has no Trash to move to.
    var movesDeletedItemsToTrash: Bool { false }

    func deleteItem(at url: URL) async throws {
        _ = try await run(.remove, [url.path])
    }

    func moveItem(at url: URL, to destination: URL) async throws {
        _ = try await run(.move, [url.path, destination.path])
    }

    /// Only the latest set matters, so whichever call reaches the helper last
    /// still sends it.
    func watch(_ folders: [URL]) {
        watchedFolders = folders
        Task { [weak self] in
            guard let helper = await self?.helper?.value, let self else { return }
            helper.watch(watchedFolders.map(\.path))
        }
    }

    /// Starts a helper and hands it the folders being watched once it's up.
    private func launchHelper() {
        lastLaunch = .now
        helper = Task { [weak self, connection, changes] in
            let helper = await SSHRemoteHelper.start(connection: connection, scripts: Self.scripts, changes: changes)
            if let helper, let folders = self?.watchedFolders, !folders.isEmpty { helper.watch(folders.map(\.path)) }
            return helper
        }
    }

    private func run(_ script: Script, _ arguments: [String], input: Data? = nil) async throws -> Data {
        let launch = helper
        if let helper = await launch?.value, helper.isRunning {
            return try await helper.run(script.rawValue, arguments, input: input)
        }
        // Concurrent callers share one relaunch: only the first to find this
        // launch dead starts another, and the rest wait on it. Requests that
        // failed with the old helper aren't retried, since a create may have landed.
        if launch == helper, connection.state == .connected, ContinuousClock.now - lastLaunch >= Self.relaunchInterval {
            launchHelper()
        }
        if launch != helper, let helper = await helper?.value, helper.isRunning {
            return try await helper.run(script.rawValue, arguments, input: input)
        }
        return try await connection.execute(
            program: "python3", arguments: ["-c", script.source] + arguments, standardInput: input
        ).standardOutput
    }

    private struct RemoteEntry: Decodable {
        let name: String
        let directory: Bool
        let size: Int?
        let mtime: Double?
    }

    static let listScript = #"""
    import json, os, sys
    path = os.path.abspath(os.path.expanduser(sys.argv[1]))
    show_hidden = sys.argv[2] == "1"
    result = []
    with os.scandir(path) as entries:
        for entry in entries:
            if not show_hidden and entry.name.startswith("."):
                continue
            try:
                stat = entry.stat(follow_symlinks=False)
                size, mtime = stat.st_size, stat.st_mtime
            except OSError:
                size = mtime = None
            result.append({"name": entry.name, "directory": entry.is_dir(follow_symlinks=True), "size": size, "mtime": mtime})
    print(json.dumps(result, ensure_ascii=False))
    """#

    /// Like `listScript`, but walks the whole tree; `name` is relative to the root.
    static let findScript = #"""
    import json, os, sys
    root = os.path.abspath(os.path.expanduser(sys.argv[1]))
    query, show_hidden, limit = sys.argv[2].casefold(), sys.argv[3] == "1", int(sys.argv[4])
    result = []
    for parent, folders, files in os.walk(root):
        if not show_hidden:
            folders[:] = [name for name in folders if not name.startswith(".")]
        for name in folders + files:
            if len(result) >= limit or (not show_hidden and name.startswith(".")) or query not in name.casefold():
                continue
            path = os.path.join(parent, name)
            try:
                stat = os.lstat(path)
                size, mtime = stat.st_size, stat.st_mtime
            except OSError:
                size = mtime = None
            result.append({"name": os.path.relpath(path, root), "directory": name in folders, "size": size, "mtime": mtime})
        if len(result) >= limit:
            break
    print(json.dumps(result, ensure_ascii=False))
    """#

    static let readScript = #"""
    import sys
    path, limit = sys.argv[1], int(sys.argv[2])
    with open(path, "rb") as file:
        sys.stdout.buffer.write(file.read(limit))
    """#

    static let writeScript = #"""
    import os, sys, tempfile
    path = os.path.abspath(sys.argv[1])
    parent = os.path.dirname(path)
    descriptor, temporary = tempfile.mkstemp(prefix=".TypeNBash-", dir=parent)
    try:
        with os.fdopen(descriptor, "wb") as file:
            file.write(sys.stdin.buffer.read())
            file.flush()
            os.fsync(file.fileno())
        if os.path.exists(path):
            os.chmod(temporary, os.stat(path).st_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
    """#

    static let createFileScript = #"""
    import sys
    with open(sys.argv[1], "xb") as file:
        file.write(sys.stdin.buffer.read())
    """#

    static let mkdirScript = #"""
    import os, sys
    os.mkdir(os.path.abspath(os.path.expanduser(sys.argv[1])))
    """#

    /// `os.rename` replaces an existing file silently, so an existing
    /// destination is refused unless it is the source itself, as it is for a
    /// case-only rename on a case-insensitive disk.
    static let moveScript = #"""
    import os, sys
    source = os.path.abspath(os.path.expanduser(sys.argv[1]))
    target = os.path.abspath(os.path.expanduser(sys.argv[2]))
    if os.path.lexists(target):
        old, new = os.lstat(source), os.lstat(target)
        if (old.st_dev, old.st_ino) != (new.st_dev, new.st_ino):
            raise FileExistsError("An item named " + os.path.basename(target) + " already exists")
    os.rename(source, target)
    """#

    /// Permanent: the host has no Trash. A link is unlinked rather than
    /// followed, and `/` and the home folder are refused outright.
    static let removeScript = #"""
    import os, shutil, sys
    path = os.path.abspath(os.path.expanduser(sys.argv[1]))
    if path in ("/", os.path.abspath(os.path.expanduser("~"))):
        raise PermissionError("Refusing to delete " + path)
    if os.path.isdir(path) and not os.path.islink(path):
        shutil.rmtree(path)
    else:
        os.unlink(path)
    """#
}
