import Foundation

/// Portable project settings. Paths are relative to the folder containing this file.
struct ProjectManifest: Codable, Hashable, Sendable {
    static let filename = ".typenbash.json"
    static let byteLimit = 64 * 1024
    var version = 1
    var name: String
    var outputDirectory = "output"

    func validate() throws {
        guard version == 1 else { throw ProjectSetupError.invalid("Unsupported project format version \(version).") }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProjectSetupError.invalid("The project definition needs a name.")
        }
        try Self.validateFolderName(outputDirectory)
    }

    static func validateFolderName(_ name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name != ".", name != "..", !name.contains("/"),
              !name.contains("\\"), !name.contains("\0"), name != filename else {
            throw ProjectSetupError.invalid("Use a single folder name, without path separators or ‘..’.")
        }
    }

    static func load(in root: URL, fileSystem: any WorkspaceFileSystem) async throws -> Self? {
        let entries = try await fileSystem.contentsOfDirectory(at: root, includingHiddenFiles: true)
        guard let entry = entries.first(where: { $0.url.lastPathComponent == filename }) else { return nil }
        guard !entry.isDirectory, (entry.byteCount ?? 0) <= byteLimit else {
            throw ProjectSetupError.invalid("The project definition must be a JSON file smaller than 64 KB.")
        }
        let data = try await fileSystem.readFile(at: entry.url, maximumByteCount: byteLimit + 1)
        guard data.count <= byteLimit else { throw ProjectSetupError.invalid("The project definition is too large.") }
        let manifest: Self
        do { manifest = try JSONDecoder().decode(Self.self, from: data) }
        catch { throw ProjectSetupError.invalid("Could not read \(filename): \(error.localizedDescription)") }
        try manifest.validate()
        return manifest
    }

    func create(in root: URL, fileSystem: any WorkspaceFileSystem) async throws {
        try validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Task.checkCancellation()
        try await fileSystem.createFile(encoder.encode(self), at: root.appendingPathComponent(Self.filename))
    }
}

enum ProjectSetupError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self { case .invalid(let message): message }
    }
}
