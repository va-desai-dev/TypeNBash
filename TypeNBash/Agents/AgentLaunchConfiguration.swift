import Foundation

/// How much a headless agent may do without asking. Headless runs cannot
/// prompt, so anything outside the chosen mode is denied and reported back as
/// a failed tool call.
enum AgentPermissionMode: String, CaseIterable, Identifiable, Sendable {
    case plan
    case acceptEdits
    case bypassPermissions

    var id: Self { self }

    var title: String {
        switch self {
        case .plan: "Plan Only"
        case .acceptEdits: "Accept Edits"
        case .bypassPermissions: "Full Access"
        }
    }

    var systemImage: String {
        switch self {
        case .plan: "doc.text.magnifyingglass"
        case .acceptEdits: "pencil"
        case .bypassPermissions: "exclamationmark.shield"
        }
    }
}

struct AgentLaunchRequest: Sendable {
    var permissionMode: AgentPermissionMode
    /// Continues an earlier conversation in the same root instead of starting fresh.
    var resumeSessionID: String?

    /// Claude Code in print mode, streaming one JSON event per line. The prompt
    /// arrives on stdin so it can never be parsed as a flag.
    var claudeCodeArguments: [String] {
        var arguments = [
            "--print", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--permission-mode", permissionMode.rawValue
        ]
        if let resumeSessionID { arguments += ["--resume", resumeSessionID] }
        return arguments
    }
}

struct AgentLaunchConfiguration: Sendable {
    let executableURL: URL
    let arguments: [String]
    let environment: [String: String]
    /// The project root; the agent treats it as its working tree.
    let workingDirectory: URL

    static func localClaudeCode(
        _ request: AgentLaunchRequest,
        workingDirectory: URL
    ) async throws -> AgentLaunchConfiguration {
        let path = try await loginShellPath()
        guard let executable = path.split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent("claude") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
        else { throw AgentError.missingExecutable("claude") }

        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = path
        environment.merge(GitCredentialBroker.shared.localEnvironment()) { $1 }
        return AgentLaunchConfiguration(
            executableURL: executable,
            arguments: request.claudeCodeArguments,
            environment: environment,
            workingDirectory: workingDirectory
        )
    }

    private static var cachedLoginPath: String?

    /// A Dock-launched app inherits launchd's minimal PATH rather than the
    /// user's, so the CLI is found the way the app's own terminal would find it.
    /// The marker separates PATH from anything the user's startup files print.
    private static func loginShellPath() async throws -> String {
        if let cachedLoginPath { return cachedLoginPath }
        let marker = "__TYPENBASH_PATH__"
        let shell = Process()
        let output = Pipe()
        shell.executableURL = URL(fileURLWithPath: "/bin/zsh")
        shell.arguments = ["-ilc", "print -rn -- \(marker)$PATH"]
        shell.standardInput = FileHandle.nullDevice
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        try shell.run()
        let handle = output.fileHandleForReading
        let data = try await Task.detached { try handle.readToEnd() ?? Data() }.value
        let path = String(decoding: data, as: UTF8.self).components(separatedBy: marker).last ?? ""
        guard !path.isEmpty else { throw AgentError.missingExecutable("claude") }
        cachedLoginPath = path
        return path
    }
}

enum AgentError: LocalizedError {
    case missingExecutable(String)
    case remoteUnsupported
    case exited(status: Int32, message: String)

    var errorDescription: String? {
        switch self {
        case .missingExecutable(let name):
            "`\(name)` was not found on your shell's PATH. Install Claude Code and confirm `\(name)` runs in the terminal."
        case .remoteUnsupported:
            "Agents are not available for SSH projects yet."
        case .exited(let status, let message):
            message.isEmpty ? "The agent exited with status \(status)." : message
        }
    }
}
