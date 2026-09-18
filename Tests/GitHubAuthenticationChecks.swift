import Foundation
import libgit2
@testable import TypeNBash

final class GitHubAPIFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        precondition(request.url?.absoluteString == "https://api.github.com/user")
        precondition(request.httpMethod == "GET")
        let token = request.value(forHTTPHeaderField: "Authorization")
        let status = token == "Bearer fixture-invalid" ? 401 : token == "Bearer fixture-denied" ? 403 : 200
        let body = token == "Bearer fixture-malformed" ? "{}" : #"{"login":"fixture-user","id":123}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

@main
struct GitHubAuthenticationChecks {
    static func main() async throws {
        // This isolated Keychain service never reads or changes the user's account.
        let store = GitHubCredentialStore(service: "com.TypeNBash.tests.github.\(UUID())")
        defer { try? store.delete() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubAPIFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let service = GitHubAuthenticationService(store: store, session: session)
        let empty = try store.read()
        precondition(empty == nil)
        let login = try await service.connect(token: " fixture-good \n")
        precondition(login == "fixture-user")
        var credential = try store.read()
        precondition(credential?.token == "fixture-good")
        let restored = try await service.savedLogin()
        precondition(restored == login)
        for token in ["fixture-invalid", "fixture-denied", "fixture-malformed", "", "two tokens"] {
            do {
                _ = try await service.connect(token: token)
                fatalError("Invalid authentication unexpectedly succeeded")
            } catch {
                precondition(!error.localizedDescription.contains(token) || token.isEmpty)
            }
            credential = try store.read()
            precondition(credential?.token == "fixture-good", "Failed replacement must preserve the saved credential")
        }
        _ = try await service.connect(token: "fixture-replacement")
        credential = try store.read()
        precondition(credential?.token == "fixture-replacement")
        try await service.disconnect()
        credential = try store.read()
        precondition(credential == nil)
        try await service.disconnect()

        precondition(git_libgit2_init() >= 0)
        defer { git_libgit2_shutdown() }
        let sample = GitHubCredential(login: "fixture-user", token: "fixture-secret")
        for address in ["http://github.com/a/b.git", "https://github.com.evil.test/a/b.git",
                        "https://gitlab.com/a/b.git", "https://github.com:8443/a/b.git",
                        "https://user:secret@github.com/a/b.git", "ssh://git@github.com/a/b.git"] {
            let context = GitHubCredentialContext(sample)
            var output: UnsafeMutablePointer<git_credential>?
            let result = context.acquire(&output, url: address, allowed: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue)
            precondition(result == GIT_EAUTH.rawValue && output == nil)
        }
        let context = GitHubCredentialContext(sample)
        var output: UnsafeMutablePointer<git_credential>?
        let first = context.acquire(&output, url: "https://github.com/a/b.git",
                                    allowed: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue)
        precondition(first == 0 && output != nil)
        git_credential_free(output)
        output = nil
        let repeated = context.acquire(&output, url: "https://github.com/a/b.git",
                                       allowed: GIT_CREDENTIAL_USERPASS_PLAINTEXT.rawValue)
        precondition(repeated == GIT_EAUTH.rawValue && output == nil)
        try await deviceFlowChecks()
        print("GitHub auth checks passed: mocked validation, denied/expired/malformed responses, Keychain save/restore/replace/delete, credential host restrictions, and bounded retry. No GitHub requests made.")
    }
}

final class GitHubDeviceFixture: URLProtocol, @unchecked Sendable {
    static let lock = NSLock()
    static var replies: [String] = []
    static var tokenRequests = 0
    static var deviceError: String?

    static func configure(_ replies: [String], deviceError: String? = nil) {
        lock.lock()
        defer { lock.unlock() }
        Self.replies = replies
        Self.deviceError = deviceError
        tokenRequests = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        if request.url?.host == "github.com" {
            precondition(request.httpMethod == "POST")
            var data = request.httpBody ?? Data()
            if let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let parameters = try! JSONDecoder().decode([String: String].self, from: data)
            precondition(parameters["client_id"] == "Ov23lihUjhUuaNtKRHxL")
            precondition(parameters["client_secret"] == nil)
            if request.url?.path == "/login/device/code" {
                precondition(parameters["scope"] == "repo read:user")
            } else {
                precondition(parameters["grant_type"] == "refresh_token"
                             || parameters["grant_type"] == "urn:ietf:params:oauth:grant-type:device_code")
            }
        }
        Self.lock.lock()
        switch request.url!.absoluteString {
        case "https://github.com/login/device/code":
            body = Self.deviceError.map { "{\"error\":\"\($0)\"}" }
                ?? #"{"device_code":"fixture-device","user_code":"ABCD-EFGH","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#
        case "https://github.com/login/oauth/access_token":
            Self.tokenRequests += 1
            precondition(!Self.replies.isEmpty, "Unexpected extra token request")
            body = Self.replies.removeFirst()
        case "https://api.github.com/user": body = #"{"login":"fixture-user","id":123}"#
        default: fatalError("Unexpected OAuth destination")
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { }
}

actor DevicePollingClock {
    var intervals: [TimeInterval] = []
    func pause(_ interval: TimeInterval) { intervals.append(interval) }
}

extension GitHubAuthenticationChecks {
    static func deviceFlowChecks() async throws {
        let store = GitHubCredentialStore(service: "com.TypeNBash.tests.device.\(UUID())")
        defer { try? store.delete() }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [GitHubDeviceFixture.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = DevicePollingClock()
        let service = GitHubAuthenticationService(store: store, session: session, pause: { await clock.pause($0) })
        GitHubDeviceFixture.configure([
            #"{"error":"authorization_pending"}"#,
            #"{"error":"slow_down","interval":10}"#,
            #"{"access_token":"fixture-device-token","token_type":"bearer","expires_in":28800,"refresh_token":"fixture-refresh","refresh_token_expires_in":15897600}"#
        ])
        let code = try await service.beginDeviceLogin()
        precondition(code.userCode == "ABCD-EFGH")
        let login = try await service.finishDeviceLogin(code)
        precondition(login == "fixture-user")
        let intervals = await clock.intervals
        precondition(intervals == [5, 5, 10])
        var saved = try store.read()!
        precondition(saved.refreshToken == "fixture-refresh" && saved.expiresAt != nil)
        saved = GitHubCredential(login: saved.login, token: saved.token,
                                 expiresAt: Date().addingTimeInterval(-1),
                                 refreshToken: saved.refreshToken,
                                 refreshExpiresAt: Date().addingTimeInterval(3600))
        try store.save(saved)
        GitHubDeviceFixture.configure([
            #"{"access_token":"fixture-rotated","token_type":"bearer","expires_in":28800,"refresh_token":"fixture-refresh-rotated","refresh_token_expires_in":15897600}"#
        ])
        async let first = service.validCredential()
        async let second = service.validCredential()
        let refreshed = try await (first, second)
        precondition(refreshed.0?.token == "fixture-rotated" && refreshed.1?.token == "fixture-rotated")
        precondition(GitHubDeviceFixture.tokenRequests == 1)
        precondition(tryReadToken(store) == "fixture-rotated")

        for error in ["access_denied", "expired_token", "incorrect_client_credentials"] {
            GitHubDeviceFixture.configure(["{\"error\":\"\(error)\"}"])
            do {
                _ = try await service.finishDeviceLogin(code)
                fatalError("Device error unexpectedly succeeded")
            } catch { precondition(tryReadToken(store) == "fixture-rotated") }
        }
        GitHubDeviceFixture.configure([], deviceError: "device_flow_disabled")
        do {
            _ = try await service.beginDeviceLogin()
            fatalError("Disabled device flow unexpectedly succeeded")
        } catch { precondition(error.localizedDescription.contains("Enable Device Flow")) }
        GitHubDeviceFixture.configure([])
        let expired = GitHubDeviceCode(deviceCode: "expired", userCode: "expired", expiresAt: .distantPast, interval: 5)
        do {
            _ = try await service.finishDeviceLogin(expired)
            fatalError("Expired code unexpectedly polled")
        } catch { precondition(GitHubDeviceFixture.tokenRequests == 0) }
        let waiting = GitHubAuthenticationService(store: store, session: session, pause: { _ in
            try await Task.sleep(for: .seconds(30))
        })
        let pending = Task { try await waiting.finishDeviceLogin(code) }
        pending.cancel()
        do {
            _ = try await pending.value
            fatalError("Cancelled login succeeded")
        } catch is CancellationError { }
        precondition(GitHubDeviceFixture.tokenRequests == 0 && tryReadToken(store) == "fixture-rotated")
        print("Device flow checks passed: pending/backoff, account validation, refresh rotation/coalescing, denial, expiry, disabled registration, and cancellation.")
    }

    static func tryReadToken(_ store: GitHubCredentialStore) -> String? { try? store.read()?.token }
}
