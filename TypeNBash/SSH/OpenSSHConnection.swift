import Foundation
import Observation

struct SSHCommandResult: Sendable {
    let standardOutput: Data
    let standardError: Data
    let terminationStatus: Int32
}

@MainActor
@Observable
final class OpenSSHConnection {
    enum State: Equatable {
        case idle
        case connecting
        case connected
        case failed(String)
    }

    let profile: SSHConnectionProfile
    private(set) var state: State = .idle

    private var authentication: SSHAuthentication
    private var masterProcess: Process?
    private var masterErrorPipe: Pipe?
    private var controlDirectory: URL?
    private var controlPath: URL?
    private var askPassSecretURL: URL?
    private var askPassHelperURL: URL?

    init(
        profile: SSHConnectionProfile,
        authentication: SSHAuthentication = .keyOrAgent
    ) {
        self.profile = profile
        self.authentication = authentication
    }

    func connect(timeout: Duration = .seconds(15)) async throws {
        guard !profile.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SSHConnectionError.invalidProfile("An SSH host is required.")
        }
        guard state != .connected else { return }

        disconnect()
        state = .connecting

        // OpenSSH control sockets use sockaddr_un, whose path limit is much
        // shorter than a typical macOS per-user temporary-directory path.
        let directory = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("TypeNBash-ssh-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let socket = directory.appendingPathComponent("control.sock")
        controlDirectory = directory
        controlPath = socket

        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = masterArguments(controlPath: socket)
        process.standardOutput = Pipe()
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        try configureAuthentication(for: process, in: directory)
        masterProcess = process
        masterErrorPipe = errorPipe

        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            cleanupControlDirectory()
            throw SSHConnectionError.connectionFailed(error.localizedDescription)
        }

        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if !process.isRunning {
                let message = readMasterError()
                state = .failed(message)
                cleanupControlDirectory()
                throw SSHConnectionError.connectionFailed(message)
            }

            if await controlCheck(socket: socket) {
                try Task.checkCancellation()
                cleanupAskPassArtifacts()
                authentication = .keyOrAgent
                state = .connected
                return
            }
            try await Task.sleep(for: .milliseconds(120))
        }

        disconnect()
        state = .failed(SSHConnectionError.connectionTimedOut.localizedDescription)
        throw SSHConnectionError.connectionTimedOut
    }

    func disconnect() {
        if let masterProcess, masterProcess.isRunning { masterProcess.terminate() }
        masterProcess = nil
        masterErrorPipe = nil
        cleanupControlDirectory()
        if state != .idle { state = .idle }
    }

    func execute(
        program: String,
        arguments: [String] = [],
        standardInput: Data? = nil
    ) async throws -> SSHCommandResult {
        guard state == .connected, let socket = controlPath, masterProcess?.isRunning == true else {
            throw SSHConnectionError.disconnected
        }

        try Task.checkCancellation()
        let remoteCommand = ([program] + arguments)
            .map(TerminalShellIntegration.posixQuote)
            .joined(separator: " ")
        let result = try await OpenSSHProcess.run(
            arguments: commandArguments(controlPath: socket, remoteCommand: remoteCommand),
            standardInput: standardInput
        )
        try Task.checkCancellation()
        guard result.terminationStatus == 0 else {
            let message = String(decoding: result.standardError, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw SSHConnectionError.commandFailed(
                status: result.terminationStatus,
                message: message
            )
        }
        return result
    }

    func makeTerminalConfiguration(workingDirectory: URL) throws -> TerminalLaunchConfiguration {
        guard state == .connected, let socket = controlPath, masterProcess?.isRunning == true else {
            throw SSHConnectionError.disconnected
        }

        // Installs the OSC 7 / OSC 133 hooks on the remote host so `cd` there
        // reports back the same way a local shell does. Setup must succeed
        // before an interactive managed shell is started.
        let remoteShell = TerminalShellIntegration.remoteLaunchCommand(
            workingDirectory: workingDirectory.path
        )
        return TerminalLaunchConfiguration(
            executablePath: "/usr/bin/ssh",
            arguments: ["ssh"] + sharedArguments + [
                "-S", socket.path,
                "-o", "ControlMaster=no",
                "-o", "BatchMode=yes",
                "-o", "ProxyCommand=false",
                "-tt",
                "--", profile.destination,
                remoteShell
            ],
            environmentOverrides: [:],
            workingDirectory: FileManager.default.homeDirectoryForCurrentUser,
            installsLocalShellIntegration: false
        )
    }

    private var sharedArguments: [String] {
        var result: [String] = []
        if let port = profile.port { result += ["-p", String(port)] }
        if let identityFile = profile.identityFile { result += ["-i", identityFile.path] }
        return result
    }

    private func masterArguments(controlPath: URL) -> [String] {
        var arguments = [
            "-M", "-N",
            "-o", "ControlMaster=yes",
            "-o", "ControlPersist=no",
            "-o", "ExitOnForwardFailure=yes",
            "-o", "ConnectTimeout=15",
            "-o", "ServerAliveInterval=15",
            "-o", "ServerAliveCountMax=3",
            "-S", controlPath.path
        ]
        switch authentication {
        case .keyOrAgent:
            arguments += ["-o", "BatchMode=yes"]
        case .password:
            arguments += [
                "-o", "BatchMode=no",
                "-o", "PasswordAuthentication=yes",
                "-o", "KbdInteractiveAuthentication=yes",
                "-o", "NumberOfPasswordPrompts=3",
                "-o", "StrictHostKeyChecking=yes"
            ]
        }
        return arguments + sharedArguments + ["--", profile.destination]
    }

    private func commandArguments(controlPath: URL, remoteCommand: String) -> [String] {
        sharedArguments + [
            "-S", controlPath.path,
            "-o", "ControlMaster=no",
            "-o", "BatchMode=yes",
            "-o", "ProxyCommand=false",
            "--", profile.destination,
            remoteCommand
        ]
    }

    private func controlArguments(socket: URL, operation: String) -> [String] {
        sharedArguments + ["-S", socket.path, "-O", operation, "--", profile.destination]
    }

    private func controlCheck(socket: URL) async -> Bool {
        guard let result = try? await OpenSSHProcess.run(
            arguments: controlArguments(socket: socket, operation: "check")
        ) else {
            return false
        }
        return result.terminationStatus == 0
    }

    private func readMasterError() -> String {
        guard let masterErrorPipe,
              let data = try? masterErrorPipe.fileHandleForReading.readToEnd(),
              !data.isEmpty else {
            return "The SSH master process exited before the connection was ready."
        }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func cleanupControlDirectory() {
        cleanupAskPassArtifacts()
        if let controlDirectory {
            try? FileManager.default.removeItem(at: controlDirectory)
        }
        controlDirectory = nil
        controlPath = nil
    }

    private func configureAuthentication(for process: Process, in directory: URL) throws {
        guard case .password(let password) = authentication else { return }

        let secretURL = directory.appendingPathComponent("askpass-secret")
        let helperURL = directory.appendingPathComponent("askpass")
        let secretData = Data((password + "\n").utf8)
        let helper = "#!/bin/sh\nexec /bin/cat \"$TypeNBash_SSH_ASKPASS_FILE\"\n"

        guard FileManager.default.createFile(
            atPath: secretURL.path,
            contents: secretData,
            attributes: [.posixPermissions: 0o600]
        ), FileManager.default.createFile(
            atPath: helperURL.path,
            contents: Data(helper.utf8),
            attributes: [.posixPermissions: 0o700]
        ) else {
            cleanupControlDirectory()
            throw SSHConnectionError.connectionFailed(
                "Could not prepare the one-time SSH authentication helper."
            )
        }

        askPassSecretURL = secretURL
        askPassHelperURL = helperURL
        var environment = ProcessInfo.processInfo.environment
        environment["SSH_ASKPASS"] = helperURL.path
        environment["SSH_ASKPASS_REQUIRE"] = "force"
        environment["TypeNBash_SSH_ASKPASS_FILE"] = secretURL.path
        environment["DISPLAY"] = environment["DISPLAY"] ?? "TypeNBash"
        process.environment = environment
    }

    private func cleanupAskPassArtifacts() {
        if let askPassSecretURL {
            try? FileManager.default.removeItem(at: askPassSecretURL)
        }
        if let askPassHelperURL {
            try? FileManager.default.removeItem(at: askPassHelperURL)
        }
        askPassSecretURL = nil
        askPassHelperURL = nil
    }
}

private enum OpenSSHProcess {
    @MainActor
    static func run(
        arguments: [String],
        standardInput: Data? = nil
    ) async throws -> SSHCommandResult {
        let process = Process()
        let runDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("TypeNBash-SSH-Command-\(UUID().uuidString)", isDirectory: true)
        let outputURL = runDirectory.appendingPathComponent("stdout")
        let errorURL = runDirectory.appendingPathComponent("stderr")
        let inputURL = runDirectory.appendingPathComponent("stdin")

        try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        guard FileManager.default.createFile(atPath: outputURL.path, contents: nil),
              FileManager.default.createFile(atPath: errorURL.path, contents: nil) else {
            try? FileManager.default.removeItem(at: runDirectory)
            throw CocoaError(.fileWriteUnknown)
        }

        let outputHandle = try FileHandle(forWritingTo: outputURL)
        let errorHandle = try FileHandle(forWritingTo: errorURL)
        let inputHandle: FileHandle?
        if let standardInput {
            try standardInput.write(to: inputURL, options: .atomic)
            inputHandle = try FileHandle(forReadingFrom: inputURL)
        } else {
            inputHandle = nil
        }

        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        process.standardOutput = outputHandle
        process.standardError = errorHandle
        process.standardInput = inputHandle ?? FileHandle.nullDevice

        defer {
            try? outputHandle.close()
            try? errorHandle.close()
            try? inputHandle?.close()
            try? FileManager.default.removeItem(at: runDirectory)
        }
        try Task.checkCancellation()
        try process.run()
        do {
            while process.isRunning {
                try await Task.sleep(for: .milliseconds(30))
            }
            try Task.checkCancellation()
            return SSHCommandResult(
                standardOutput: (try? Data(contentsOf: outputURL)) ?? Data(),
                standardError: (try? Data(contentsOf: errorURL)) ?? Data(),
                terminationStatus: process.terminationStatus
            )
        } catch {
            if process.isRunning { process.terminate() }
            throw error
        }
    }
}
