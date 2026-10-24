import Foundation
import Observation

/// Whether an SSH host may borrow this Mac's GitHub sign-in. Off until chosen,
/// and remembered per SSH profile so opting one server in never opts in another.
nonisolated enum GitHubLending {
    static func isEnabled(for profileID: UUID) -> Bool {
        UserDefaults.standard.bool(forKey: key(for: profileID))
    }

    static func setEnabled(_ enabled: Bool, for profileID: UUID) {
        UserDefaults.standard.set(enabled, forKey: key(for: profileID))
    }

    private static func key(for profileID: UUID) -> String {
        "SourceControl.LendsGitHubSignIn.\(profileID.uuidString)"
    }
}

/// One app-wide answer to "does GitHub still accept the sign-in?", so a
/// rejection noticed anywhere — Source Control, a console `git push`, a
/// remote host — shows the same "Sign in again" everywhere.
@MainActor
@Observable
final class GitHubSignInStatus {
    static let shared = GitHubSignInStatus()
    private(set) var needsSignIn = false

    func markExpired() { needsSignIn = true }
    func clear() { needsSignIn = false }
}

/// Answers Git credential requests from TypeNBash's own consoles with the
/// TypeNBash GitHub sign-in, the way VS Code's integrated terminal does.
///
/// Each console is launched with Git configured (through `GIT_CONFIG_*`, so
/// nothing on disk changes) to use a helper that forwards the request to this
/// broker over a Unix socket. The helper carries a per-console nonce that only
/// processes started in that console inherit, and the broker also checks the
/// peer is this user. SSH consoles reach the same socket through a forward on
/// the workspace's control connection.
///
/// Only `https://github.com` is configured to ask, and the token is handed out
/// per request — refreshed if needed — never exported into a shell.
nonisolated final class GitCredentialBroker: @unchecked Sendable {
    static let shared = GitCredentialBroker()

    enum Scope: Sendable {
        case local
        case remote(UUID)
    }

    /// Nil when the socket couldn't be created; consoles then keep Git's
    /// own configuration.
    let socketPath: String?
    private let helperPath: String?
    private let lock = NSLock()
    private var scopes: [String: Scope] = [:]

    private init() {
        // Short fixed prefix: sockaddr_un paths are limited to 104 bytes.
        let directory = "/tmp/TypeNBash-git-\(UUID().uuidString)"
        let socket = directory + "/broker.sock"
        let helper = directory + "/git-credential-typenbash"
        guard (try? FileManager.default.createDirectory(
                atPath: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])) != nil,
              FileManager.default.createFile(atPath: helper, contents: Data(Self.localHelper.utf8),
                                             attributes: [.posixPermissions: 0o700]),
              let descriptor = Self.listen(at: socket) else {
            socketPath = nil
            helperPath = nil
            return
        }
        socketPath = socket
        helperPath = helper
        let thread = Thread { [unowned self] in self.acceptLoop(descriptor) }
        thread.name = "TypeNBash Git credential broker"
        thread.start()
    }

    // MARK: Console environments

    /// Environment for a console on this Mac.
    func localEnvironment() -> [String: String] {
        guard let socketPath, let helperPath else { return [:] }
        return Self.environment(broker: socketPath, nonce: register(.local), helper: helperPath)
    }

    /// Environment for a console on an SSH host whose end of the forwarded
    /// socket is `remoteSocket`. The host runs a Python helper because the
    /// remote workspace already depends on `python3`.
    func remoteEnvironment(profileID: UUID, remoteSocket: String) -> [String: String] {
        guard socketPath != nil else { return [:] }
        return Self.environment(broker: remoteSocket, nonce: register(.remote(profileID)),
                                helper: "!python3 -c '\(Self.remoteHelper)'")
    }

    /// The first entry clears helpers configured anywhere else for github.com,
    /// so this console answers with TypeNBash's sign-in and nothing can store
    /// the token; the second installs ours.
    private static func environment(broker: String, nonce: String, helper: String) -> [String: String] {
        [
            "TYPENBASH_GIT_BROKER": broker,
            "TYPENBASH_GIT_NONCE": nonce,
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_0": "",
            "GIT_CONFIG_KEY_1": "credential.https://github.com.helper",
            "GIT_CONFIG_VALUE_1": helper
        ]
    }

    private func register(_ scope: Scope) -> String {
        let nonce = (UUID().uuidString + UUID().uuidString).replacingOccurrences(of: "-", with: "")
        lock.withLock { scopes[nonce] = scope }
        return nonce
    }

    private func scope(for nonce: String) -> Scope? {
        lock.withLock { scopes[nonce] }
    }

    // MARK: Answering requests

    private struct Request {
        var fields: [String: String] = [:]

        /// "key=value" lines up to the first blank line: the helper's nonce and
        /// action, then Git's own credential attributes.
        init(_ data: Data) {
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
                if line.isEmpty { break }
                guard let equals = line.firstIndex(of: "=") else { continue }
                let key = String(line[..<equals])
                if fields[key] == nil { fields[key] = String(line[line.index(after: equals)...]) }
            }
        }
    }

    private func reply(to request: Request) async -> String {
        guard let nonce = request.fields["nonce"], let scope = scope(for: nonce) else {
            return Self.stop("This terminal is no longer connected to TypeNBash. Open a new terminal.")
        }
        // Only GitHub over HTTPS is configured to ask; anything else is refused
        // rather than answered with a GitHub token.
        guard request.fields["protocol"] == "https",
              ["github.com", "github.com:443"].contains(request.fields["host"] ?? "") else { return "" }

        if request.fields["action"] == "erase" {
            // Git erases a credential the server just rejected. Only the current
            // token counts; an older one being erased says nothing new.
            let current = try? GitHubAuthenticationService.shared.store.read()?.token
            guard let current, request.fields["password"] == current else { return "" }
            await MainActor.run { GitHubSignInStatus.shared.markExpired() }
            return Self.message("GitHub no longer accepts your sign-in. Open Source Control and choose Sign in again.")
        }
        guard request.fields["action"] == "get" else { return "" }

        if case .remote(let profileID) = scope, !GitHubLending.isEnabled(for: profileID) {
            return Self.stop("GitHub sign-in is off for this host. Turn on “Use my GitHub sign-in on this host” in Source Control, then open a new terminal.")
        }
        do {
            guard let credential = try await GitHubAuthenticationService.shared.validCredential() else {
                return Self.stop("Sign in with GitHub in Source Control to push and pull from this terminal.")
            }
            return "username=\(credential.login)\npassword=\(credential.token)\n"
        } catch GitHubDeviceFlowError.signInAgain {
            await MainActor.run { GitHubSignInStatus.shared.markExpired() }
            return Self.stop("Your GitHub sign-in expired. Open Source Control and choose Sign in again.")
        } catch {
            return Self.stop(error.localizedDescription)
        }
    }

    /// A line the helper prints to the terminal instead of passing to Git.
    private static func message(_ text: String) -> String {
        "typenbash-message=\(text)\n"
    }

    /// Tells Git to stop rather than fall back to a password prompt GitHub
    /// would refuse anyway.
    private static func stop(_ text: String) -> String {
        message(text) + "quit=1\n"
    }

    // MARK: Socket

    private static func listen(at path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(descriptor)
            return nil
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, Darwin.listen(descriptor, 16) == 0 else {
            close(descriptor)
            return nil
        }
        chmod(path, 0o600)
        return descriptor
    }

    private func acceptLoop(_ listener: Int32) {
        while true {
            let connection = accept(listener, nil, nil)
            if connection < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(connection)
        }
    }

    private func serve(_ connection: Int32) {
        // The socket's directory is private already; this rejects anything
        // that isn't this user even if that ever changes.
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(connection, &uid, &gid) == 0, uid == getuid() else {
            close(connection)
            return
        }
        var enabled: Int32 = 1
        setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        let terminator = Data("\n\n".utf8)
        while data.count < 64 * 1024 {
            let count = read(connection, &buffer, buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
            if data.range(of: terminator) != nil { break }
        }
        let request = Request(data)
        Task {
            let reply = Data(await self.reply(to: request).utf8)
            reply.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(connection, bytes.baseAddress! + offset, bytes.count - offset)
                    guard written > 0 else { break }
                    offset += written
                }
            }
            close(connection)
        }
    }

    // MARK: Helpers

    /// Runs on this Mac. `nc` ships with macOS, where `python3` may not.
    private static let localHelper = #"""
    #!/bin/sh
    # TypeNBash Git credential helper: asks the running app for its GitHub sign-in.
    case "$1" in get|erase) ;; *) exit 0 ;; esac
    request=$(cat)
    if [ ! -S "${TYPENBASH_GIT_BROKER:-}" ]; then
      echo "TypeNBash: cannot reach the app for your GitHub sign-in. Open a new terminal." >&2
      echo quit=1
      exit 0
    fi
    printf 'nonce=%s\naction=%s\n%s\n\n' "$TYPENBASH_GIT_NONCE" "$1" "$request" |
      /usr/bin/nc -U "$TYPENBASH_GIT_BROKER" |
      while IFS= read -r line; do
        case "$line" in
          typenbash-message=*) printf 'TypeNBash: %s\n' "${line#typenbash-message=}" >&2 ;;
          *) printf '%s\n' "$line" ;;
        esac
      done
    """#

    /// Runs on an SSH host as `python3 -c '…'`, so it must not contain a
    /// single quote.
    private static let remoteHelper = #"""
    import os, socket, sys
    action = sys.argv[1] if len(sys.argv) > 1 else ""
    if action not in ("get", "erase"):
        sys.exit(0)
    request = sys.stdin.read().strip("\n")
    try:
        connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        connection.settimeout(60)
        connection.connect(os.environ["TYPENBASH_GIT_BROKER"])
        nonce = os.environ.get("TYPENBASH_GIT_NONCE", "")
        connection.sendall(("nonce=%s\naction=%s\n%s\n\n" % (nonce, action, request)).encode())
        reply = b""
        while True:
            chunk = connection.recv(4096)
            if not chunk:
                break
            reply += chunk
    except (OSError, KeyError):
        sys.stderr.write("TypeNBash: cannot reach the app for your GitHub sign-in. Open a new terminal.\n")
        print("quit=1")
        sys.exit(0)
    for line in reply.decode("utf-8", "replace").splitlines():
        if line.startswith("typenbash-message="):
            sys.stderr.write("TypeNBash: " + line[len("typenbash-message="):] + "\n")
        else:
            print(line)
    """#
}
