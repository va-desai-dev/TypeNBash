import Foundation

/// Agent file access on an SSH host, through the workspace's persistent remote
/// helper. The remote script walks descriptor-relative from the project root
/// with the same link, size, text and revision rules as `AgentWorkspaceAccess`.
nonisolated final class AgentRemoteWorkspaceAccess: AgentFileAccess {
    /// The project root as the host spells it; never resolved against this Mac.
    let root: URL
    let fileSystem: SSHWorkspaceFileSystem

    init(root: URL, fileSystem: SSHWorkspaceFileSystem) {
        self.root = root.standardizedFileURL
        self.fileSystem = fileSystem
    }

    func list(_ path: String) async throws -> [(name: String, directory: Bool)] {
        _ = try AgentWorkspaceAccess.components(path, allowRoot: true)
        let entries = try await run("list", path).array
        return try entries.map {
            guard let name = $0["name"].string, case .bool(let directory) = $0["directory"],
                  (try? AgentWorkspaceAccess.components(name)) != nil else { throw AgentFailure("The host returned an invalid listing.") }
            return (name, directory)
        }
    }

    func read(_ path: String) async throws -> Data {
        _ = try AgentWorkspaceAccess.components(path)
        let data = try await raw("read", path)
        guard data.count <= AgentWorkspaceAccess.byteLimit, !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw AgentFailure("Only UTF-8 text files up to 1 MiB are supported.")
        }
        return data
    }

    func commit(_ change: AgentFileChange) async throws {
        _ = try AgentWorkspaceAccess.components(change.path)
        let after = Data((change.after ?? "").utf8)
        guard after.count <= AgentWorkspaceAccess.byteLimit else { throw AgentFailure("Edit exceeds 1 MiB.") }
        let request = Commit(directory: change.isDirectory, replacing: change.before != nil, revision: change.revision, after: after)
        _ = try await raw("commit", change.path, input: JSONEncoder().encode(request))
    }

    func search(_ path: String, query: String, offset: Int) async throws -> String {
        _ = try AgentWorkspaceAccess.components(path, allowRoot: true)
        return try await run("search", path, [query, String(offset)]).encoded
    }

    private struct Commit: Encodable {
        let directory: Bool
        let replacing: Bool
        let revision: String
        let after: Data
    }

    private func run(_ action: String, _ path: String, _ extra: [String] = []) async throws -> AgentJSON {
        let data = try await raw(action, path, extra)
        guard let value = try? JSONDecoder().decode(AgentJSON.self, from: data) else {
            throw AgentFailure("The host returned an invalid response.")
        }
        return value
    }

    /// Script refusals arrive as `ValueError: …`; only that message reaches the
    /// model. Anything else is a transport or host failure.
    private func raw(_ action: String, _ path: String, _ extra: [String] = [], input: Data? = nil) async throws -> Data {
        let excluded = String(decoding: try JSONEncoder().encode(AgentWorkspaceAccess.excluded.sorted()), as: UTF8.self)
        do {
            return try await fileSystem.agentWorkspace([action, root.path, path, excluded] + extra, input: input)
        } catch SSHConnectionError.commandFailed(_, let message) {
            let last = message.split(separator: "\n").last.map(String.init) ?? message
            if last.hasPrefix("ValueError: ") { throw AgentFailure(String(last.dropFirst("ValueError: ".count))) }
            throw AgentFailure("The SSH host could not complete this file operation: \(last)")
        } catch let error as SSHConnectionError {
            throw AgentFailure("SSH workspace unavailable: \(error.localizedDescription)")
        }
    }

    /// Run by the remote helper as `agent ACTION ROOT PATH EXCLUDED [EXTRA…]`.
    /// Each component is opened relative to its parent with O_NOFOLLOW, so no
    /// link anywhere under the root is followed.
    static let remoteScript = #"""
    import base64, hashlib, json, os, stat, sys, uuid
    action, root, relative, excluded = sys.argv[1], sys.argv[2], sys.argv[3], set(json.loads(sys.argv[4]))
    LIMIT = 1048576
    NOFOLLOW = os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0)
    DIRECTORY = os.O_RDONLY | os.O_DIRECTORY | NOFOLLOW

    def allowed(name):
        return (name not in ("", ".", "..") and "\0" not in name and name not in excluded
            and not name.startswith(".env.") and not name.endswith((".pem", ".key")))

    def parts(path, allow_root=False):
        if allow_root and path in ("", "."):
            return []
        names = path.split("/")
        if path.startswith("/") or not all(allowed(name) for name in names):
            raise ValueError("Use a project-relative path without traversal, credentials, or excluded directories.")
        return names

    def directory(names):
        try:
            fd = os.open(os.path.realpath(os.path.expanduser(root)), DIRECTORY)
        except OSError:
            raise ValueError("Cannot open the authorized workspace.")
        for name in names:
            try:
                child = os.open(name, DIRECTORY, dir_fd=fd)
            except OSError:
                raise ValueError("Directory is unavailable or contains a symbolic link.")
            finally:
                os.close(fd)
            fd = child
        return fd

    def read(parent, name):
        try:
            fd = os.open(name, os.O_RDONLY | os.O_NONBLOCK | NOFOLLOW, dir_fd=parent)
        except OSError:
            raise ValueError("File is unavailable or is a symbolic link.")
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1 or info.st_size > LIMIT:
                raise ValueError("Only regular, single-link text files up to 1 MiB are supported.")
            chunks, size = [], 0
            while True:
                chunk = os.read(fd, 65536)
                if not chunk:
                    break
                size += len(chunk)
                if size > LIMIT:
                    raise ValueError("File exceeds 1 MiB.")
                chunks.append(chunk)
        finally:
            os.close(fd)
        data = b"".join(chunks)
        try:
            if b"\0" in data:
                raise UnicodeError
            data.decode("utf-8")
        except UnicodeError:
            raise ValueError("Only UTF-8 text files are supported.")
        return data

    def listing(fd):
        entries = []
        with os.scandir(fd) as scan:
            for entry in scan:
                if not allowed(entry.name):
                    continue
                try:
                    info = entry.stat(follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISDIR(info.st_mode) or (stat.S_ISREG(info.st_mode) and info.st_nlink == 1):
                    entries.append((entry.name, stat.S_ISDIR(info.st_mode)))
                    if len(entries) > 10000:
                        raise ValueError("Directory exceeds 10,000 entries; choose a narrower directory.")
        return sorted(entries)

    def revision(parent, name):
        return hashlib.sha256(read(parent, name)).hexdigest()

    def commit(parent, name, change):
        if change["directory"]:
            try:
                os.mkdir(name, 0o755, dir_fd=parent)
            except OSError:
                raise ValueError("Directory already exists or cannot be created.")
            return
        data = base64.b64decode(change["after"])
        if len(data) > LIMIT:
            raise ValueError("Edit exceeds 1 MiB.")
        mode = 0o644
        if change["replacing"]:
            if revision(parent, name) != change["revision"]:
                raise ValueError("File changed after it was read. Read it again before editing.")
            mode = os.stat(name, dir_fd=parent, follow_symlinks=False).st_mode & 0o777
        temporary = ".typenbash-agent-" + str(uuid.uuid4()).upper()
        try:
            fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | NOFOLLOW, mode, dir_fd=parent)
        except OSError:
            raise ValueError("Cannot prepare file edit.")
        try:
            try:
                view = memoryview(data)
                while view:
                    view = view[os.write(fd, view):]
                os.fchmod(fd, mode)
                os.fsync(fd)
            except OSError:
                raise ValueError("Cannot write file edit.")
            finally:
                os.close(fd)
            if change["replacing"]:
                if revision(parent, name) != change["revision"]:
                    raise ValueError("File changed while preparing the edit.")
                try:
                    os.rename(temporary, name, src_dir_fd=parent, dst_dir_fd=parent)
                except OSError:
                    raise ValueError("Cannot apply file edit.")
            else:
                # Exclusive creation: never replace an existing file, including a link.
                try:
                    os.link(temporary, name, src_dir_fd=parent, dst_dir_fd=parent, follow_symlinks=False)
                except OSError:
                    raise ValueError("File already exists or cannot be created.")
        finally:
            try:
                os.unlink(temporary, dir_fd=parent)
            except OSError:
                pass

    def search(start, query, offset):
        wanted = offset + 100
        queue, visited, files, skipped, matches = [start], 0, 0, 0, []
        while visited < len(queue) and visited < 200 and files < 2000 and len(matches) < wanted:
            current = queue[visited]
            visited += 1
            fd = directory(parts(current, True))
            try:
                for name, is_directory in listing(fd):
                    child = name if current in ("", ".") else current + "/" + name
                    if is_directory:
                        if len(queue) < 201:
                            queue.append(child)
                        continue
                    if files >= 2000 or len(matches) >= wanted:
                        break
                    files += 1
                    try:
                        text = read(fd, name).decode("utf-8")
                    except (OSError, ValueError):
                        skipped += 1
                        continue
                    for number, line in enumerate(text.split("\n")):
                        if query in line:
                            matches.append({"path": child, "line": number + 1, "text": line[:300]})
                            if len(matches) >= wanted:
                                break
            finally:
                os.close(fd)
        return {"matches": matches[offset:offset + 100], "skipped_files": skipped,
            "scan_limited": visited < len(queue) or files >= 2000 or len(matches) >= wanted}

    if action == "list":
        fd = directory(parts(relative, True))
        try:
            entries = listing(fd)
        finally:
            os.close(fd)
        print(json.dumps([{"name": name, "directory": is_directory} for name, is_directory in entries]))
    elif action == "search":
        print(json.dumps(search(relative, sys.argv[5], int(sys.argv[6]))))
    else:
        names = parts(relative)
        parent = directory(names[:-1])
        try:
            if action == "read":
                sys.stdout.buffer.write(read(parent, names[-1]))
            elif action == "commit":
                commit(parent, names[-1], json.load(sys.stdin))
            else:
                raise ValueError("Unknown workspace action.")
        finally:
            os.close(parent)
    """#
}
