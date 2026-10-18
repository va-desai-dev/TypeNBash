import Foundation
import CryptoKit
import Darwin

nonisolated struct AgentFileChange: Codable, Sendable, Identifiable {
    var id = UUID()
    let path: String
    let before: String?
    let after: String?
    let revision: String
    var isDirectory = false
    var review: String {
        if isDirectory { return "Create directory: \(path)" }
        return "\(path)\n\nBEFORE\n\(before ?? "(new file)")\n\nAFTER\n\(after ?? "")"
    }
}

/// Descriptor-relative access rejects symlinks at every component, including
/// creation parents. Native tools never follow project links outside the root.
nonisolated final class AgentWorkspaceAccess: @unchecked Sendable {
    let root: URL
    private let descriptor: Int32
    static let byteLimit = 1_048_576
    static let excluded = Set([".git", ".ssh", ".aws", ".env", ".DS_Store", "node_modules", ".build", "DerivedData"])

    init(root: URL) throws {
        self.root = root.resolvingSymlinksInPath().standardizedFileURL
        descriptor = Darwin.open(self.root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw AgentFailure("Cannot open the authorized workspace.") }
    }

    deinit { Darwin.close(descriptor) }

    static func revision(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    func components(_ path: String, allowRoot: Bool = false) throws -> [String] {
        if allowRoot && (path == "." || path.isEmpty) { return [] }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !path.hasPrefix("/"), !path.contains("\0"), !parts.isEmpty,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !Self.excluded.contains($0)
                  && !$0.hasPrefix(".env.") && !$0.hasSuffix(".pem") && !$0.hasSuffix(".key") }) else {
            throw AgentFailure("Use a project-relative path without traversal, credentials, or excluded directories.")
        }
        return parts
    }

    private func directory(_ parts: [String]) throws -> Int32 {
        var fd = dup(descriptor)
        guard fd >= 0 else { throw AgentFailure("Cannot access workspace.") }
        for part in parts {
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            Darwin.close(fd)
            guard next >= 0 else { throw AgentFailure("Directory is unavailable or contains a symbolic link.") }
            fd = next
        }
        return fd
    }

    func read(_ path: String) throws -> Data {
        let parts = try components(path)
        let parent = try directory(Array(parts.dropLast()))
        defer { Darwin.close(parent) }
        return try read(parent: parent, name: parts.last!)
    }

    private func read(parent: Int32, name: String) throws -> Data {
        let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw AgentFailure("File is unavailable or is a symbolic link.") }
        defer { Darwin.close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_nlink == 1, info.st_size <= Self.byteLimit else {
            throw AgentFailure("Only regular, single-link text files up to 1 MiB are supported.")
        }
        var data = Data()
        var bytes = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &bytes, bytes.count)
            if count == 0 { break }
            if count < 0 { if errno == EINTR { continue }; throw AgentFailure("File read failed.") }
            data.append(contentsOf: bytes.prefix(count))
            guard data.count <= Self.byteLimit else { throw AgentFailure("File exceeds 1 MiB.") }
        }
        guard !data.contains(0), String(data: data, encoding: .utf8) != nil else {
            throw AgentFailure("Only UTF-8 text files are supported.")
        }
        return data
    }

    func list(_ path: String) throws -> [(name: String, directory: Bool)] {
        let fd = try directory(components(path, allowRoot: true))
        guard let stream = fdopendir(fd) else { Darwin.close(fd); throw AgentFailure("Cannot list directory.") }
        defer { closedir(stream) }
        var entries: [(String, Bool)] = []
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            guard (try? components(name)) != nil else { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let type = info.st_mode & S_IFMT
            guard type == S_IFDIR || (type == S_IFREG && info.st_nlink == 1) else { continue }
            entries.append((name, type == S_IFDIR))
            guard entries.count <= 10_000 else { throw AgentFailure("Directory exceeds 10,000 entries; choose a narrower directory.") }
        }
        return entries.sorted { $0.0 < $1.0 }
    }

    /// Called on the main actor immediately after the editor-conflict check.
    /// Small, bounded commits cannot interleave with an editor mutation.
    func commit(_ change: AgentFileChange) throws {
        let parts = try components(change.path)
        let parent = try directory(Array(parts.dropLast()))
        defer { Darwin.close(parent) }
        let name = parts.last!
        if change.isDirectory {
            guard mkdirat(parent, name, 0o755) == 0 else { throw AgentFailure("Directory already exists or cannot be created.") }
            return
        }
        let data = Data((change.after ?? "").utf8)
        guard data.count <= Self.byteLimit else { throw AgentFailure("Edit exceeds 1 MiB.") }
        var mode: mode_t = 0o644
        if change.before != nil {
            guard Self.revision(try read(parent: parent, name: name)) == change.revision else {
                throw AgentFailure("File changed after it was read. Read it again before editing.")
            }
            var info = stat()
            guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw AgentFailure("File disappeared.") }
            mode = info.st_mode & 0o777
        }
        let temporary = ".typenbash-agent-" + UUID().uuidString
        let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { throw AgentFailure("Cannot prepare file edit.") }
        defer { Darwin.close(fd); unlinkat(parent, temporary, 0) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { throw AgentFailure("Cannot write file edit.") }
                offset += written
            }
        }
        guard fchmod(fd, mode) == 0 else { throw AgentFailure("Cannot preserve file permissions.") }
        if change.before != nil {
            guard Self.revision(try read(parent: parent, name: name)) == change.revision else {
                throw AgentFailure("File changed while preparing the edit.")
            }
            guard renameat(parent, temporary, parent, name) == 0 else { throw AgentFailure("Cannot apply file edit.") }
        } else {
            // Exclusive creation: never replace an existing file, including a symlink.
            guard linkat(parent, temporary, parent, name, 0) == 0 else { throw AgentFailure("File already exists or cannot be created.") }
        }
    }
}

actor AgentWorkspaceTools {
    let access: AgentWorkspaceAccess
    init(root: URL) throws { access = try AgentWorkspaceAccess(root: root) }

    nonisolated static var definitions: [AgentToolDefinition] {
        func string(_ description: String) -> AgentJSON { .object(["type": .string("string"), "description": .string(description)]) }
        let path = string("Project-relative path; use . for the root directory. Symbolic links and credential files are excluded.")
        let offset: AgentJSON = .object(["type": .string("integer"), "minimum": .number(0)])
        return [
            .init(name: "list_files", description: "List up to 200 immediate children. Advance offset for more.", properties: ["path": path, "offset": offset]),
            .init(name: "search_files", description: "Search UTF-8 file contents for a literal string, recursively. Bounded scan; no shell.", properties: ["path": path, "query": string("Nonempty literal text"), "offset": offset]),
            .init(name: "read_file", description: "Read up to 200 lines, capped at 32,000 characters, with a SHA-256 revision for edits.", properties: ["path": path, "offset": offset]),
            .init(name: "create_file", description: "Create a UTF-8 file without replacing anything.", properties: ["path": path, "content": string("Complete file content")]),
            .init(name: "create_directory", description: "Create one directory; parent must already exist.", properties: ["path": path]),
            .init(name: "apply_edits", description: "Replace one unique exact text match in a file with the revision returned by read_file.", properties: ["path": path, "revision": string("SHA-256 from read_file"), "old_text": string("Unique, nonempty exact text"), "new_text": string("Replacement text")])
        ]
    }

    func prepare(_ call: AgentToolCall) throws -> AgentFileChange {
        let path = try required("path", call)
        _ = try access.components(path)
        if call.name == "create_directory" {
            return AgentFileChange(path: path, before: nil, after: nil, revision: "", isDirectory: true)
        }
        if call.name == "create_file" {
            let content = try required("content", call)
            guard content.utf8.count <= AgentWorkspaceAccess.byteLimit, !content.contains("\0") else { throw AgentFailure("Invalid or oversized text content.") }
            return AgentFileChange(path: path, before: nil, after: content, revision: "")
        }
        guard call.name == "apply_edits" else { throw AgentFailure("Unknown edit tool.") }
        let data = try access.read(path)
        let revision = try required("revision", call)
        guard revision == AgentWorkspaceAccess.revision(data) else { throw AgentFailure("Stale revision. Read the file again.") }
        let before = String(decoding: data, as: UTF8.self)
        let old = try required("old_text", call)
        let new = try required("new_text", call)
        guard !old.isEmpty, before.components(separatedBy: old).count == 2, !new.contains("\0") else {
            throw AgentFailure("old_text must match exactly once; replacement must be text.")
        }
        let after = before.replacingOccurrences(of: old, with: new)
        guard after.utf8.count <= AgentWorkspaceAccess.byteLimit else { throw AgentFailure("Edit exceeds 1 MiB.") }
        return AgentFileChange(path: path, before: before, after: after, revision: revision)
    }

    func read(_ call: AgentToolCall) throws -> String {
        try Task.checkCancellation()
        let path = try required("path", call)
        guard let offset = call.arguments["offset"].integer, offset >= 0, offset <= 100_000 else { throw AgentFailure("Invalid offset.") }
        switch call.name {
        case "list_files":
            let entries = try access.list(path)
            return AgentJSON.object(["entries": .array(entries.dropFirst(offset).prefix(200).map {
                .object(["name": .string($0.name), "directory": .bool($0.directory)])
            }), "next_offset": offset + 200 < entries.count ? .number(Double(offset + 200)) : .null]).encoded
        case "read_file":
            let data = try access.read(path)
            let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
            let text = lines.dropFirst(offset).prefix(200).joined(separator: "\n")
            return AgentJSON.object(["revision": .string(AgentWorkspaceAccess.revision(data)),
                "content": .string(String(text.prefix(32_000))), "truncated": .bool(text.count > 32_000),
                "next_offset": offset + 200 < lines.count ? .number(Double(offset + 200)) : .null]).encoded
        case "search_files":
            let query = try required("query", call)
            guard !query.isEmpty, query.count <= 1_000 else { throw AgentFailure("Use a nonempty query up to 1,000 characters.") }
            var queue = [path], visited = 0, files = 0, matches: [AgentJSON] = []
            var skipped = 0
            while visited < queue.count && visited < 200 && files < 2_000 && matches.count < offset + 100 {
                try Task.checkCancellation()
                let directory = queue[visited]; visited += 1
                for entry in try access.list(directory) {
                    try Task.checkCancellation()
                    let child = directory == "." || directory.isEmpty ? entry.name : directory + "/" + entry.name
                    if entry.directory { if queue.count < 201 { queue.append(child) }; continue }
                    if files >= 2_000 || matches.count >= offset + 100 { break }
                    files += 1
                    guard let data = try? access.read(child) else { skipped += 1; continue }
                    for (line, text) in String(decoding: data, as: UTF8.self).components(separatedBy: "\n").enumerated() where text.contains(query) {
                        matches.append(.object(["path": .string(child), "line": .number(Double(line + 1)), "text": .string(String(text.prefix(300)))]))
                        if matches.count >= offset + 100 { break }
                    }
                }
            }
            return AgentJSON.object(["matches": .array(Array(matches.dropFirst(offset).prefix(100))),
                "scan_limited": .bool(visited < queue.count || files >= 2_000 || matches.count >= offset + 100),
                "skipped_files": .number(Double(skipped))]).encoded
        default: throw AgentFailure("Unknown workspace tool.")
        }
    }

    private func required(_ key: String, _ call: AgentToolCall) throws -> String {
        guard let value = call.arguments[key].string else { throw AgentFailure("Missing string argument: \(key).") }
        return value
    }
}
