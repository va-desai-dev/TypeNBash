import Foundation

/// Quick Look needs a local URL. Own an isolated snapshot for both local and SSH
/// files, keeping the source untouched and removing the snapshot on release.
nonisolated final class WordPreviewDocument: Sendable {
    let url: URL
    private let directory: URL

    init(data: Data) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeNBash-Word-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent("Document.docx")
        do {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
        self.directory = directory
        self.url = url
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }
}
