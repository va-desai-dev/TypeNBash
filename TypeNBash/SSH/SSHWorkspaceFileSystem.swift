import Foundation

final class SSHWorkspaceFileSystem: WorkspaceFileSystem {
    let homeDirectory: URL

    private let connection: OpenSSHConnection

    init(connection: OpenSSHConnection, homeDirectory: URL) {
        self.connection = connection
        self.homeDirectory = homeDirectory
    }

    func contentsOfDirectory(
        at directory: URL,
        includingHiddenFiles: Bool
    ) async throws -> [WorkspaceFileEntry] {
        let script = #"""
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
                    size = stat.st_size
                except OSError:
                    size = None
                result.append({"name": entry.name, "directory": entry.is_dir(follow_symlinks=True), "size": size})
        print(json.dumps(result, ensure_ascii=False))
        """#
        let result = try await connection.execute(
            program: "python3",
            arguments: ["-c", script, directory.path, includingHiddenFiles ? "1" : "0"]
        )
        let records: [RemoteEntry]
        do {
            records = try JSONDecoder().decode([RemoteEntry].self, from: result.standardOutput)
        } catch {
            throw WorkspaceFileSystemError.invalidResponse(error.localizedDescription)
        }
        return records.map { record in
            WorkspaceFileEntry(
                url: directory.appendingPathComponent(record.name, isDirectory: record.directory),
                isDirectory: record.directory,
                byteCount: record.size
            )
        }
    }

    func readFile(at url: URL, maximumByteCount: Int) async throws -> Data {
        // Stream at most `maximumByteCount` bytes (a prefix) over the connection, so
        // a large remote file previews the same way a local one does.
        let script = #"""
        import sys
        path, limit = sys.argv[1], int(sys.argv[2])
        with open(path, "rb") as file:
            sys.stdout.buffer.write(file.read(limit))
        """#
        let result = try await connection.execute(
            program: "python3",
            arguments: ["-c", script, url.path, String(maximumByteCount)]
        )
        return result.standardOutput
    }

    func writeFile(_ data: Data, to url: URL) async throws {
        let script = #"""
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
        _ = try await connection.execute(
            program: "python3",
            arguments: ["-c", script, url.path],
            standardInput: data
        )
    }

    func editorGitBaseline(at url: URL) async throws -> String? {
        let result = try await connection.execute(
            program: "python3", arguments: ["-c", RemoteGit.editorBaselineScript, url.path]
        )
        return try JSONDecoder().decode(String?.self, from: result.standardOutput)
    }

    func createFile(_ data: Data, at url: URL) async throws {
        let script = #"""
        import sys
        with open(sys.argv[1], "xb") as file:
            file.write(sys.stdin.buffer.read())
        """#
        _ = try await connection.execute(program: "python3", arguments: ["-c", script, url.path], standardInput: data)
    }

    func createDirectory(at url: URL) async throws {
        // One level only, like local. A traceback on stderr from an existing name
        // becomes a nonzero exit, which `execute` turns into a thrown error.
        let script = #"""
        import os, sys
        os.mkdir(os.path.abspath(os.path.expanduser(sys.argv[1])))
        """#
        _ = try await connection.execute(
            program: "python3",
            arguments: ["-c", script, url.path]
        )
    }

    private struct RemoteEntry: Decodable {
        let name: String
        let directory: Bool
        let size: Int?
    }
}
