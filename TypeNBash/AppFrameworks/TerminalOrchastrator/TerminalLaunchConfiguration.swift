import Foundation

struct TerminalLaunchConfiguration: Sendable {
    let executablePath: String
    let arguments: [String]
    let environmentOverrides: [String: String]
    /// Local directory inherited by the launched process.
    let workingDirectory: URL
    let installsLocalShellIntegration: Bool
    /// Retains the selected folder's grant until the terminal has been torn down.
    var workspaceGrant: WorkspaceFolderGrant? = nil

    static func localShell(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TerminalLaunchConfiguration {
        #if APP_STORE
        TerminalLaunchConfiguration(
            executablePath: "/bin/zsh", arguments: ["zsh", "-d", "-i"],
            environmentOverrides: [:], workingDirectory: workingDirectory,
            installsLocalShellIntegration: false
        )
        #else
        TerminalLaunchConfiguration(
            executablePath: "/bin/zsh",
            arguments: ["-zsh", "-i"],
            // `git push` typed here signs in as TypeNBash's GitHub account.
            environmentOverrides: GitCredentialBroker.shared.localEnvironment(),
            workingDirectory: workingDirectory,
            installsLocalShellIntegration: true
        )
        #endif
    }
}
