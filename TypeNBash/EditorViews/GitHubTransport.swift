import Foundation
import libgit2

/// Synchronous callback state, retained only for the duration of a libgit2 fetch.
nonisolated final class GitHubCredentialContext {
    let credential: GitHubCredential
    private var supplied = false
    init(_ credential: GitHubCredential) { self.credential = credential }

    static func accepts(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host?.lowercased() == "github.com"
            && (url.port == nil || url.port == 443) && url.user == nil && url.password == nil
    }

    func acquire(_ output: UnsafeMutablePointer<UnsafeMutablePointer<git_credential>?>?,
                 url: String, allowed: UInt32) -> Int32 {
        guard !supplied, let remote = URL(string: url), Self.accepts(remote),
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
        guard let address = git_remote_url(remote),
              let url = URL(string: String(cString: address)), GitHubCredentialContext.accepts(url) else {
            throw GitHubAuthenticationError.unsafeRemote
        }
        var options = git_fetch_options()
        guard git_fetch_options_init(&options, UInt32(GIT_FETCH_OPTIONS_VERSION)) == 0 else {
            throw GitHubAuthenticationError.transport
        }
        let context = Unmanaged.passRetained(GitHubCredentialContext(credential))
        defer { context.release() }
        options.callbacks.payload = context.toOpaque()
        options.callbacks.credentials = { output, url, _, allowed, payload in
            guard let url, let payload else { return GIT_EAUTH.rawValue }
            return Unmanaged<GitHubCredentialContext>.fromOpaque(payload).takeUnretainedValue()
                .acquire(output, url: String(cString: url), allowed: allowed)
        }
        // Retain libgit2's default certificate verification and prohibit redirects.
        options.follow_redirects = GIT_REMOTE_REDIRECT_NONE
        guard git_remote_fetch(remote, nil, &options, nil) == 0 else {
            // Avoid surfacing transport strings that could contain sensitive URLs.
            throw GitHubAuthenticationError.transport
        }
    }
}
