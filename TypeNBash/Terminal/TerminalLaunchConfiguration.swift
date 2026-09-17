import Foundation

struct TerminalLaunchConfiguration: Sendable {
    let executablePath: String
    let arguments: [String]
    let environmentOverrides: [String: String]
    /// Local directory inherited by the launched process.
    let workingDirectory: URL
    let installsLocalShellIntegration: Bool

    static func localShell(
        workingDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> TerminalLaunchConfiguration {
        TerminalLaunchConfiguration(
            executablePath: "/bin/zsh",
            arguments: ["-zsh", "-i"],
            environmentOverrides: [:],
            workingDirectory: workingDirectory,
            installsLocalShellIntegration: true
        )
    }
}
