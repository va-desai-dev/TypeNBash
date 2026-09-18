import Foundation
import libgit2

/// Synchronous callback state, retained only for the duration of a libgit2 transfer.
nonisolated final class GitHubCredentialContext {
    let credential: GitHubCredential?
    var rejected = false
    private var supplied = false
    init(_ credential: GitHubCredential?) { self.credential = credential }

    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func acquire(_ output: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
                 url: String, allowed: UInt32) -> Int32 {
        guard let credential, !supplied, let remote = URL(string: url), Self.accepts(remote),
              allowed & GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue != 0 else {
            return GIT_EAUTH.rawValue
        }
        supplied = true
        return git_credential_userpass_plaintext_new(output, credential.login, credential.token)
    }
}

nonisolated enum GitHubTransport {
    /// SwiftGitX does not currently expose fetch callbacks. Open a separate
    /// libgit2 handle rather than accessing its private repository pointer.
    static func fetch(root: URL, remote name: String, credential: GitHubCredential) throws {
        try transfer(root: root, remote: name, credential: credential, pushing: false)
    }

    static func push(root: URL, remote name: String, credential: GitHubCredential?) throws {
        try transfer(root: root, remote: name, credential: credential, pushing: true)
    }

    private static func transfer(root: URL, remote name: String,
                                 credential: GitHubCredential?, pushing: Bool) throws {
        guard git_libgit2_init() >= 0 else { throw GitHubAuthenticationError.transport }
        defer { git_libgit2_shutdown() }
        var repository: OpaquePointer?
        guard git_repository_open(&repository, root.path) == 0, let repository else {
            throw GitHubAuthenticationError.transport
        }
        defer { git_repository_free(repository) }
        var remote: OpaquePointer?
        guard git_remote_lookup(&remote, repository, name) == 0, let remote else {
            throw GitHubAuthenticationError.transport
        }
        defer { git_remote_free(remote) }
        let address = pushing ? (git_remote_pushurl(remote) ?? git_remote_url(remote)) : git_remote_url(remote)
        if credential != nil {
            guard let address, let url = URL(string: String(cString: address)),
                  GitHubCredentialContext.accepts(url) else {
                throw GitHubAuthenticationError.unsafeRemote
            }
        }
        let context = Unmanaged.passRetained(GitHubCredentialContext(credential))
        defer { context.release() }
        var callbacks = git_remote_callbacks()
        guard git_remote_init_callbacks(&callbacks, UInt32(GIT_REMOTE_CALLBACKS_VERSION)) == 0 else {
            throw GitHubAuthenticationError.transport
        }
        callbacks.payload = context.toOpaque()
        if credential != nil {
            callbacks.credentials = { output, url, _, allowed, payload in
                guard let url, let payload else { return GIT_EAUTH.rawValue }
                return Unmanaged<GitHubCredentialContext>.fromOpaque(payload).takeUnretainedValue()
                    .acquire(output, url: String(cString: url), allowed: allowed)
            }
        }
        if pushing {
            guard git_repository_head_detached(repository) == 0,
                  git_repository_head_unborn(repository) == 0 else { throw GitPushError.noBranch }
            var head: OpaquePointer?
            guard git_repository_head(&head, repository) == 0, let head else { throw GitPushError.noBranch }
            defer { git_reference_free(head) }
            guard let reference = git_reference_name(head) else { throw GitPushError.noBranch }
            let branch = String(cString: reference)
            guard branch.hasPrefix("refs/heads/") else { throw GitPushError.noBranch }
            var options = git_push_options()
            guard git_push_options_init(&options, UInt32(GIT_PUSH_OPTIONS_VERSION)) == 0 else {
                throw GitPushError.failed
            }
            callbacks.push_update_reference = { _, status, payload in
                if status != nil, let payload {
                    Unmanaged<GitHubCredentialContext>.fromOpaque(payload).takeUnretainedValue().rejected = true
                }
                return 0
            }
            options.callbacks = callbacks
            options.follow_redirects = GIT_REMOTE_REDIRECT_NONE
            // An explicit, non-forced refspec pushes only this branch, regardless
            // of any broad or force-push refspecs in the remote configuration.
            let spec = strdup("\(branch):\(branch)")!
            defer { free(spec) }
            var pointer: UnsafeMutablePointer<CChar>? = spec
            let status = withUnsafeMutablePointer(to: &pointer) { strings in
                var specs = git_strarray(strings: strings, count: 1)
                return git_remote_push(remote, &specs, &options)
            }
            if context.takeUnretainedValue().rejected { throw GitPushError.rejected }
            if status == GIT_ENONFASTFORWARD.rawValue { throw GitPushError.diverged }
            guard status == 0 else { throw GitPushError.failed }
        } else {
            var options = git_fetch_options()
            guard git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)) == 0 else {
                throw GitHubAuthenticationError.transport
            }
            options.callbacks = callbacks
            options.follow_redirects = GIT_REMOTE_REDIRECT_NONE
            guard git_remote_fetch(remote, nil, &options, nil) == 0 else {
                throw GitHubAuthenticationError.transport
            }
        }
    }
}

nonisolated enum GitPushError: LocalizedError {
    case noBranch, diverged, rejected, failed
    var errorDescription: String? {
        switch self {
        case .noBranch: "Check out a branch with at least one commit before pushing."
        case .diverged: "The remote branch has changes missing locally. Fetch and integrate them before pushing."
        case .rejected: "The server rejected this push. Check branch protection rules and repository permissions."
        case .failed: "Push failed. Check your connection, remote URL, and GitHub write access. If the remote has new commits, fetch and integrate them first."
        }
    }
}
