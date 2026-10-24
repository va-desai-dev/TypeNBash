#if DIRECT_DISTRIBUTION && !APP_STORE
import Foundation
import Darwin

/// Compiled only into the DMG distribution. A separate process group lets Stop
/// terminate normal descendants without disturbing the interactive terminal.
actor AgentLocalCommand {
    nonisolated static var definition: AgentToolDefinition {
        .init(name: "run_command", description: "Run a local zsh command with user approval. Not confined to the project. No interactive input or background servers.",
              properties: ["command": .object(["type": .string("string")]),
                           "timeout_seconds": .object(["type": .string("integer"), "minimum": .number(1), "maximum": .number(120)])])
    }

    func run(command: String, root: URL, timeout: Int) async throws -> String {
        guard !command.isEmpty, command.utf8.count <= 32_000, !command.contains("\0"), (1...120).contains(timeout) else {
            throw AgentFailure("Invalid command or timeout (1–120 seconds).")
        }
        try Task.checkCancellation()
        var stdout: [Int32] = [0, 0], stderr: [Int32] = [0, 0]
        guard pipe(&stdout) == 0 else { throw AgentFailure("Cannot create command output pipe.") }
        guard pipe(&stderr) == 0 else { Darwin.close(stdout[0]); Darwin.close(stdout[1]); throw AgentFailure("Cannot create command error pipe.") }
        defer { for fd in stdout + stderr { Darwin.close(fd) } }
        for fd in stdout + stderr { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        _ = fcntl(stdout[0], F_SETFL, O_NONBLOCK)
        _ = fcntl(stderr[0], F_SETFL, O_NONBLOCK)
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw AgentFailure("Cannot prepare command.") }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw AgentFailure("Cannot prepare command attributes.") }
        defer { posix_spawnattr_destroy(&attributes) }
        let codes = [
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)),
            posix_spawnattr_setpgroup(&attributes, 0),
            posix_spawn_file_actions_addchdir(&actions, root.path),
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0),
            posix_spawn_file_actions_adddup2(&actions, stdout[1], STDOUT_FILENO),
            posix_spawn_file_actions_adddup2(&actions, stderr[1], STDERR_FILENO)
        ]
        guard codes.allSatisfy({ $0 == 0 }) else { throw AgentFailure("Cannot configure command process.") }
        let allowed = Set(["PATH", "HOME", "TMPDIR", "LANG", "LC_ALL", "USER", "SHELL"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["PATH"] = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin"
        let argv = ["/bin/zsh", "-f", "-c", command].map { strdup($0) } + [nil]
        let envp = environment.sorted { $0.key < $1.key }.map { strdup($0.key + "=" + $0.value) } + [nil]
        defer { for pointer in argv + envp { free(pointer) } }
        var pid: pid_t = 0
        let launched = argv.withUnsafeBufferPointer { args in
            envp.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, args.baseAddress!, env.baseAddress!)
            }
        }
        guard launched == 0 else { throw AgentFailure("Cannot launch local command (\(launched)).") }
        var reaped = false
        defer {
            // Commands do not get to leave ordinary background descendants running.
            kill(-pid, SIGKILL)
            if !reaped { var status: Int32 = 0; while waitpid(pid, &status, 0) < 0 && errno == EINTR {} }
        }
        var output = Data(), errors = Data(), truncated = false
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var status: Int32 = 0
        while true {
            try Task.checkCancellation()
            try drain(stdout[0], into: &output, truncated: &truncated)
            try drain(stderr[0], into: &errors, truncated: &truncated)
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid {
                reaped = true
                try drain(stdout[0], into: &output, truncated: &truncated)
                try drain(stderr[0], into: &errors, truncated: &truncated)
                break
            }
            if waited < 0 && errno != EINTR { throw AgentFailure("Cannot collect command status.") }
            if ContinuousClock.now >= deadline { throw AgentFailure("Command timed out after \(timeout) seconds. Its process group was terminated.") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let signal = status & 0x7f
        return AgentJSON.object(["stdout": .string(String(decoding: output, as: UTF8.self)),
            "stderr": .string(String(decoding: errors, as: UTF8.self)), "truncated": .bool(truncated),
            "exit_code": .number(Double(signal == 0 ? (status >> 8) & 0xff : 128 + signal))]).encoded
    }

    private func drain(_ fd: Int32, into data: inout Data, truncated: inout Bool) throws {
        var buffer = [UInt8](repeating: 0, count: 8192)
        for _ in 0..<16 {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count == 0 || (count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) { return }
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw AgentFailure("Cannot read command output.") }
            let available = max(0, 32_000 - data.count)
            data.append(contentsOf: buffer.prefix(min(count, available)))
            if count > available { truncated = true }
        }
    }
}
#endif
