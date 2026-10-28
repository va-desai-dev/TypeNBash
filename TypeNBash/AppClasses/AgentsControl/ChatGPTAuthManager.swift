//
//  ChatGPTAuthManager.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/26/26.
//

import AppKit
import CryptoKit
import Foundation
import Network

/// One Keychain record per issued client ID. The registration (client ID,
/// subject, email) survives sign-out so the next sign-in reuses it.
nonisolated struct ChatGPTAccount: Codable, Sendable {
    static let keychainAccount = "chatGPT"
    static let planScope = "chatgpt.tokens.use.direct"
    var clientID: String
    var subject: String
    var email: String
    var idToken: String?
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date
    var scopes: [String]
    var isSignedIn: Bool { refreshToken != nil }
    var canUsePlan: Bool { isSignedIn && scopes.contains(Self.planScope) }

    static func load(from store: AgentCredentialStore) throws -> ChatGPTAccount? {
        try store.read(keychainAccount).map { try JSONDecoder().decode(Self.self, from: Data($0.utf8)) }
    }
    func save(to store: AgentCredentialStore) throws {
        try store.save(String(decoding: JSONEncoder().encode(self), as: UTF8.self), for: Self.keychainAccount)
    }
}

/// Sign in with ChatGPT, open-source self-serve path:
/// https://developers.openai.com/siwc/token-sharing-open-source
/// Tokens are bearer credentials for https://api.openai.com/v1/responses.
actor ChatGPTAuth {
    static let shared = ChatGPTAuth()
    private static let issuer = "https://auth.openai.com"
    private static let authorize = URL(string: issuer + "/api/accounts/authorize")!
    private static let token = URL(string: issuer + "/api/accounts/oauth/token")!
    private static let revoke = URL(string: issuer + "/api/accounts/oauth/revoke")!
    private static let resource = "https://api.openai.com/v1"
    private static let scope = "openid profile email offline_access resource.invoke " + ChatGPTAccount.planScope
    private static let terminalErrors: Set = ["invalid_grant", "invalid_refresh_token", "token_expired",
        "refresh_token_expired", "refresh_token_invalidated", "refresh_token_reused"]

    private let store = AgentCredentialStore()
    private let session = URLSession(configuration: .ephemeral, delegate: AgentRedirectPolicy(), delegateQueue: nil)
    private var refreshing: Task<ChatGPTAccount, Error>?

    /// Chosen once per Mac before the first sign-in, then reused.
    private var hostID: String {
        let key = "agent.chatgpt.hostID"
        if let existing = UserDefaults.standard.string(forKey: key) { return existing }
        let id = "urn:uuid:" + UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: key)
        return id
    }

    func signIn() async throws -> ChatGPTAccount {
        let saved = try ChatGPTAccount.load(from: store)
        // Codex CLI also listens on 1455; only the port may vary between sign-ins.
        let server: ChatGPTLoopbackServer
        do { server = try await .start(port: 1455) } catch { server = try await .start(port: 0) }
        defer { server.stop() }
        let redirect = "http://127.0.0.1:\(server.port)/auth/callback"
        let verifier = Self.random(), state = Self.random(), nonce = Self.random()
        var query = [("response_type", "code"), ("client_id", saved?.clientID ?? "dynamic_agent_client"),
                     ("redirect_uri", redirect), ("scope", Self.scope), ("resource", Self.resource),
                     ("state", state), ("nonce", nonce), ("code_challenge_method", "S256"),
                     ("code_challenge", Data(SHA256.hash(data: Data(verifier.utf8))).base64URL),
                     ("ext_agent_host_id", hostID)]
        if let saved {
            if let hint = saved.idToken { query.append(("id_token_hint", hint)) }
            query.append(("login_hint", saved.email))
            // Signing in again after plan usage was declined is the explicit request to enable it.
            if !saved.scopes.contains(ChatGPTAccount.planScope) { query.append(("prompt", "consent")) }
        } else {
            query.append(("agent_name_hint", "TypeNBash"))
        }
        var url = URLComponents(url: Self.authorize, resolvingAgainstBaseURL: false)!
        url.percentEncodedQuery = Self.form(query)
        let authorizeURL = url.url!
        guard await MainActor.run(body: { NSWorkspace.shared.open(authorizeURL) }) else { throw AgentFailure("Could not open the browser for ChatGPT sign-in.") }

        let items = try await server.callback()
        guard items["state"] == state else { throw AgentFailure("ChatGPT sign-in returned an unexpected state. Try again.") }
        if let error = items["error"] {
            throw AgentFailure(error == "access_denied" ? "ChatGPT sign-in was cancelled." : "ChatGPT sign-in failed (\(error)).")
        }
        let clientID: String
        if let saved {
            guard items["client_id"].map({ $0 == saved.clientID }) ?? true else { throw AgentFailure("ChatGPT returned a different app registration.") }
            clientID = saved.clientID
        } else {
            guard let issued = items["client_id"], !issued.isEmpty, issued != "dynamic_agent_client" else {
                throw AgentFailure("ChatGPT did not complete app registration. Try again.")
            }
            clientID = issued
        }
        guard let code = items["code"], !code.isEmpty else { throw AgentFailure("ChatGPT sign-in returned no authorization code.") }
        let (status, tokens) = try await post(Self.token, [("grant_type", "authorization_code"), ("client_id", clientID),
            ("code", code), ("code_verifier", verifier), ("redirect_uri", redirect), ("resource", Self.resource)])
        guard status == 200, let access = tokens["access_token"].string, let idToken = tokens["id_token"].string else {
            throw AgentFailure("ChatGPT token exchange failed (\(tokens["error"].string ?? "HTTP \(status)")). Try again.")
        }
        let claims = try Self.claims(idToken, clientID: clientID, nonce: nonce)
        guard let subject = claims["sub"].string, !subject.isEmpty else { throw AgentFailure("ChatGPT returned no account identity.") }
        if let saved, saved.subject != subject {
            throw AgentFailure("That ChatGPT account differs from the one registered on this Mac (\(saved.email)).")
        }
        let account = ChatGPTAccount(clientID: clientID, subject: subject, email: claims["email"].string ?? saved?.email ?? "",
            idToken: idToken, accessToken: access, refreshToken: tokens["refresh_token"].string,
            expiresAt: Date(timeIntervalSinceNow: Double(tokens["expires_in"].integer ?? 3600)),
            scopes: (tokens["scope"].string ?? items["scope"] ?? "").split(separator: " ").map(String.init))
        try account.save(to: store)
        return account
    }

    /// A current access token, refreshed near expiry. Refreshes are serialized
    /// because each one rotates the refresh token.
    func accessToken() async throws -> String {
        guard var account = try ChatGPTAccount.load(from: store), account.isSignedIn else {
            throw AgentFailure("Sign in with ChatGPT in Settings → Agents.")
        }
        guard account.canUsePlan else {
            throw AgentFailure("ChatGPT plan usage wasn’t granted. Sign in again in Settings → Agents to enable it, or use an API key.")
        }
        if account.accessToken == nil || account.expiresAt.timeIntervalSinceNow < 120 {
            let current = account
            let task = refreshing ?? Task { try await refreshed(current) }
            refreshing = task
            defer { if refreshing == task { refreshing = nil } }
            account = try await task.value
        }
        return account.accessToken ?? ""
    }

    private func refreshed(_ account: ChatGPTAccount) async throws -> ChatGPTAccount {
        var account = account
        let (status, tokens) = try await post(Self.token, [("grant_type", "refresh_token"), ("client_id", account.clientID),
            ("refresh_token", account.refreshToken ?? ""), ("resource", Self.resource)])
        guard status == 200, let access = tokens["access_token"].string else {
            let error = tokens["error"].string ?? ""
            guard Self.terminalErrors.contains(error) else {
                throw AgentFailure("Could not renew the ChatGPT sign-in (\(error.isEmpty ? "HTTP \(status)" : error)). Try again shortly.")
            }
            account.accessToken = nil; account.refreshToken = nil
            try account.save(to: store)
            throw AgentFailure("Your ChatGPT sign-in expired or was disconnected. Sign in again in Settings → Agents.")
        }
        account.accessToken = access
        account.refreshToken = tokens["refresh_token"].string ?? account.refreshToken
        account.idToken = tokens["id_token"].string ?? account.idToken
        account.expiresAt = Date(timeIntervalSinceNow: Double(tokens["expires_in"].integer ?? 3600))
        if let scope = tokens["scope"].string { account.scopes = scope.split(separator: " ").map(String.init) }
        try account.save(to: store)
        return account
    }

    /// Revokes the session but keeps the registration for the next sign-in.
    func signOut() async throws -> String {
        guard var account = try ChatGPTAccount.load(from: store) else { return "Signed out." }
        var confirmed = account.refreshToken == nil
        if let refresh = account.refreshToken {
            confirmed = (try? await post(Self.revoke, [("token", refresh), ("token_type_hint", "refresh_token"),
                                                       ("client_id", account.clientID)]).0) == 200
        }
        account.accessToken = nil; account.refreshToken = nil; account.idToken = nil
        try account.save(to: store)
        return confirmed ? "Signed out of ChatGPT."
            : "Signed out on this Mac, but OpenAI didn’t confirm revocation. You can disconnect TypeNBash in ChatGPT settings."
    }

    private func post(_ url: URL, _ fields: [(String, String)]) async throws -> (Int, AgentJSON) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.form(fields).utf8)
        let (data, response) = try await session.data(for: request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, (try? JSONDecoder().decode(AgentJSON.self, from: data)) ?? .null)
    }

    /// The ID token comes straight from the token endpoint over TLS, so per
    /// OIDC Core 3.1.3.7 the claims are checked without fetching JWKS.
    private static func claims(_ idToken: String, clientID: String, nonce: String) throws -> AgentJSON {
        let parts = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = Data(base64URL: String(parts[1])),
              let claims = try? JSONDecoder().decode(AgentJSON.self, from: payload) else { throw AgentFailure("ChatGPT returned a malformed ID token.") }
        let audience = claims["aud"].string.map { [$0] } ?? claims["aud"].array.compactMap(\.string)
        guard claims["iss"].string == issuer, audience.contains(clientID), claims["nonce"].string == nonce,
              case .number(let exp) = claims["exp"], exp > Date().timeIntervalSince1970 else {
            throw AgentFailure("ChatGPT returned an ID token that failed validation.")
        }
        return claims
    }

    private static func random() -> String { SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }.base64URL }

    private static func form(_ fields: [(String, String)]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return fields.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }.joined(separator: "&")
    }
}

/// One-shot callback listener bound to 127.0.0.1 only.
nonisolated final class ChatGPTLoopbackServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "ChatGPTLoopbackServer")
    private var ready: CheckedContinuation<Void, Error>?
    private var waiting: CheckedContinuation<[String: String], Error>?
    private var received: Result<[String: String], Error>?
    var port: UInt16 { listener.port?.rawValue ?? 0 }

    private init(port: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: port) ?? .any)
        listener = try NWListener(using: parameters)
    }

    static func start(port: UInt16) async throws -> ChatGPTLoopbackServer {
        let server = try ChatGPTLoopbackServer(port: port)
        try await withCheckedThrowingContinuation { server.begin($0) }
        return server
    }

    /// Handlers are installed before start, so `ready` is set before any state callback.
    private func begin(_ continuation: CheckedContinuation<Void, Error>) {
        ready = continuation
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready: ready?.resume(); ready = nil
            case .failed(let error), .waiting(let error):
                ready?.resume(throwing: error); ready = nil
                listener.cancel()
            case .cancelled: ready?.resume(throwing: CancellationError()); ready = nil
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] in self?.handle($0) }
        listener.start(queue: queue)
    }

    func callback() async throws -> [String: String] {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    if let received = self.received { continuation.resume(with: received) } else { self.waiting = continuation }
                }
            }
        } onCancel: { finish(.failure(CancellationError())) }
    }

    func stop() { finish(.failure(CancellationError())) }

    private func finish(_ result: Result<[String: String], Error>) {
        queue.async {
            guard self.received == nil else { return }
            self.received = result
            self.waiting?.resume(with: result); self.waiting = nil
            self.listener.cancel()
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, _, _ in
            let line = data.map { String(decoding: $0, as: UTF8.self) }?.components(separatedBy: "\r\n").first ?? ""
            let parts = line.split(separator: " ")
            guard let self, parts.count == 3, parts[0] == "GET", let target = URLComponents(string: String(parts[1])),
                  target.path == "/auth/callback" else {
                Self.respond(connection, status: "404 Not Found", body: "Not found.")
                return
            }
            Self.respond(connection, status: "200 OK", body: "TypeNBash received your ChatGPT sign-in. You can close this tab.")
            self.finish(.success(Dictionary((target.queryItems ?? []).map { ($0.name, $0.value ?? "") }) { first, _ in first }))
        }
    }

    private static func respond(_ connection: NWConnection, status: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
    }
}

nonisolated extension Data {
    var base64URL: String {
        base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    init?(base64URL: String) {
        var value = base64URL.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        self.init(base64Encoded: value)
    }
}
