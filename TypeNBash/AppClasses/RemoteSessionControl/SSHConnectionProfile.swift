import Foundation

struct SSHConnectionProfile: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    var name: String
    var host: String
    var user: String?
    var port: Int?
    var identityFile: URL?
    var remoteRoot: String?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        user: String? = nil,
        port: Int? = nil,
        identityFile: URL? = nil,
        remoteRoot: String? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.user = user
        self.port = port
        self.identityFile = identityFile
        self.remoteRoot = remoteRoot
    }

    var destination: String {
        guard let user, !user.isEmpty else { return host }
        return "\(user)@\(host)"
    }
}

/// Authentication material is intentionally separate from the codable profile
/// so passwords are never persisted with saved connection details.
enum SSHAuthentication: Sendable {
    case keyOrAgent
    case password(String)
}

enum SSHConnectionError: LocalizedError {
    case invalidProfile(String)
    case connectionFailed(String)
    case connectionTimedOut
    case commandFailed(status: Int32, message: String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let message):
            message
        case .connectionFailed(let message):
            "SSH connection failed: \(message)"
        case .connectionTimedOut:
            "The SSH connection timed out."
        case .commandFailed(let status, let message):
            "Remote command failed (\(status)): \(message)"
        case .disconnected:
            "The SSH connection is not active."
        }
    }
}
