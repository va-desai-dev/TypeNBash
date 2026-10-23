import Foundation

/// Complete, bounded reads and optimistic writes. Search never follows symlinks.
nonisolated enum ProjectSearchFileAccess {
    static func checkedURL(_ url: URL, root: URL) throws -> URL {
        let base = root.standardizedFileURL
        let root = base.resolvingSymlinksInPath().standardizedFileURL
        let path = url.standardizedFileURL
        let resolved = path.resolvingSymlinksInPath().standardizedFileURL
        guard path.pathComponents.starts(with: base.pathComponents),
              resolved.pathComponents.starts(with: root.pathComponents),
              resolved == root.appendingPathComponent(path.pathComponents.dropFirst(base.pathComponents.count).joined(separator: "/")).standardizedFileURL else {
            throw WorkspaceFileSystemError.unsupported("Search cannot follow links or leave the project root.")
        }
        return resolved
    }

    @concurrent static func entries(at directory: URL, root: URL) async throws -> [WorkspaceFileEntry] {
        let checked = try checkedURL(directory, root: root)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        return try FileManager.default.contentsOfDirectory(at: checked, includingPropertiesForKeys: Array(keys))
            .compactMap { url in
                let values = try url.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true,
                      values.isDirectory == true || values.isRegularFile == true else { return nil }
                return WorkspaceFileEntry(url: directory.appendingPathComponent(url.lastPathComponent), isDirectory: values.isDirectory == true, byteCount: values.fileSize)
            }
    }

    static func read(at url: URL, root: URL, limit: Int) throws -> Data {
        let url = try checkedURL(url, root: root)
        guard try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
            throw WorkspaceFileSystemError.unsupported("Search requires a regular text file.")
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw WorkspaceFileSystemError.fileTooLarge(limit: limit) }
        return data
    }

    @concurrent static func readFile(at url: URL, root: URL, limit: Int) async throws -> Data {
        try read(at: url, root: root, limit: limit)
    }

    @concurrent static func replace(at url: URL, root: URL, expected: Data, replacement: Data) async throws {
        let changed = WorkspaceFileSystemError.unsupported("The file changed since the search. Search again before replacing.")
        do {
            guard try read(at: url, root: root, limit: expected.count) == expected else { throw changed }
        } catch WorkspaceFileSystemError.fileTooLarge { throw changed }
        try replacement.write(to: checkedURL(url, root: root), options: .atomic)
    }

    // Run on the remote host, so remote paths are never resolved on this Mac.
    static let remoteScript = #"""
    import os, sys, json, stat, base64, tempfile
    action, root, path = sys.argv[1:4]
    base = os.path.abspath(root)
    root = os.path.realpath(base)
    path = os.path.abspath(path)
    expected_path = os.path.join(root, os.path.relpath(path, base))
    if os.path.commonpath([base, path]) != base or os.path.realpath(path) != os.path.normpath(expected_path):
        raise ValueError("Search cannot follow links or leave the project root")
    path = expected_path
    if action == "list":
        result = []
        with os.scandir(path) as entries:
            for entry in entries:
                if entry.is_symlink():
                    continue
                info = entry.stat(follow_symlinks=False)
                if stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode):
                    result.append(dict(name=entry.name, directory=stat.S_ISDIR(info.st_mode), size=info.st_size))
        print(json.dumps(result))
    else:
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise ValueError("Search requires a regular text file")
        limit = int(sys.argv[4])
        with open(path, "rb") as file:
            original = file.read(limit + 1)
        if len(original) > limit:
            raise ValueError("File exceeds the search size limit or changed since the search")
        if action == "read":
            sys.stdout.buffer.write(original)
        else:
            request = json.load(sys.stdin)
            if original != base64.b64decode(request["expected"]):
                raise ValueError("The file changed since the search. Search again before replacing.")
            descriptor, temporary = tempfile.mkstemp(prefix=".TypeNBash-", dir=os.path.dirname(path))
            try:
                with os.fdopen(descriptor, "wb") as file:
                    file.write(base64.b64decode(request["replacement"]))
                    file.flush()
                    os.fsync(file.fileno())
                os.chmod(temporary, os.stat(path).st_mode)
                os.replace(temporary, path)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    """#
}

extension LocalWorkspaceFileSystem {
    func searchEntries(at directory: URL, root: URL) async throws -> [WorkspaceFileEntry] {
        try await ProjectSearchFileAccess.entries(at: directory, root: root)
    }
    func readSearchFile(at url: URL, root: URL, limit: Int) async throws -> Data {
        try await ProjectSearchFileAccess.readFile(at: url, root: root, limit: limit)
    }
    func replaceSearchFile(at url: URL, root: URL, expected: Data, replacement: Data) async throws {
        try await ProjectSearchFileAccess.replace(at: url, root: root, expected: expected, replacement: replacement)
    }
}
