#if APP_STORE && DEBUG
import Foundation

/// Experimental local shell. The working directory is a project scope, not a
/// separate security boundary: the process still inherits the app's sandbox.
enum SandboxTerminalLaunch {
    static func prepare(_ configuration: TerminalLaunchConfiguration) throws -> (directory: URL, environment: [String]) {
        guard let grant = configuration.workspaceGrant else {
            throw AgentFailure("Open an authorized local project before starting the sandbox console.")
        }
        let root = configuration.workingDirectory.resolvingSymlinksInPath()
        guard root.pathComponents.starts(with: grant.url.resolvingSymlinksInPath().pathComponents) else {
            throw AgentFailure("The console workspace is outside the selected folder.")
        }
        let files = FileManager.default
        let home = try files.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                 appropriateFor: nil, create: true)
            .appendingPathComponent("SandboxTerminal", isDirectory: true)
        try files.createDirectory(at: home, withIntermediateDirectories: true)
        let directory = files.temporaryDirectory.appendingPathComponent("SandboxTerminal-\(UUID())", isDirectory: true)
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        do {
            try TerminalShellIntegration.sandboxZshHook.write(to: directory.appendingPathComponent(".zshrc"),
                                                             atomically: true, encoding: .utf8)
        } catch {
            try? files.removeItem(at: directory)
            throw error
        }
        // Do not inherit credentials, toolchain paths, or user startup settings.
        let environment = [
            "HOME": home.path, "ZDOTDIR": directory.path, "SHELL": "/bin/zsh",
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": files.temporaryDirectory.path,
            "TERM": "xterm-256color", "COLORTERM": "truecolor", "TERM_PROGRAM": "TypeNBash",
            "LANG": "en_US.UTF-8", "TypeNBash_START_DIRECTORY": root.path
        ]
        return (directory, environment.map { "\($0.key)=\($0.value)" })
    }
}
#endif
