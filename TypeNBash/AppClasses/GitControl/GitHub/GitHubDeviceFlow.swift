import Foundation

nonisolated struct GitHubDeviceCode: Sendable {
    let deviceCode: String
    let userCode: String
    let expiresAt: Date
    let interval: TimeInterval
}

nonisolated struct GitHubOAuthResponse: Decodable, Sendable {
    var accessToken: String?
    var tokenType: String?
    var expiresIn: TimeInterval?
    var refreshToken: String?
    var refreshTokenExpiresIn: TimeInterval?
    var error: String?
    var interval: TimeInterval?
}

nonisolated enum GitHubDeviceFlowError: LocalizedError {
    case expired, denied, disabled, client, response, signInAgain
    var errorDescription: String? {
        switch self {
        case .expired: "The GitHub code expired. Start sign-in again."
        case .denied: "GitHub authorization was declined. You can try again."
        case .disabled: "Enable Device Flow in this OAuth app’s GitHub settings, then try again."
        case .client: "GitHub did not recognize the OAuth client configuration."
        case .response: "GitHub could not complete sign-in. Try again."
        case .signInAgain: "GitHub no longer accepts your sign-in. Choose Sign in again above — nothing in your repository changes."
        }
    }
}

extension GitHubAuthenticationService {
    nonisolated static let clientID = "Ov23lihUjhUuaNtKRHxL"

    func beginDeviceLogin() async throws -> GitHubDeviceCode {
        struct Response: Decodable {
            var deviceCode: String?
            var userCode: String?
            var verificationUri: String?
            var expiresIn: TimeInterval?
            var interval: TimeInterval?
            var error: String?
        }
        let response: Response = try await oauthRequest(path: "device/code", parameters: [
            "client_id": Self.clientID, "scope": "repo read:user"
        ])
        if response.error == "device_flow_disabled" { throw GitHubDeviceFlowError.disabled }
        if response.error == "incorrect_client_credentials" { throw GitHubDeviceFlowError.client }
        guard response.error == nil, let device = response.deviceCode, !device.isEmpty,
              let user = response.userCode, !user.isEmpty,
              response.verificationUri == "https://github.com/login/device",
              let expires = response.expiresIn, expires > 0, expires <= 3600, expires.isFinite else {
            throw GitHubDeviceFlowError.response
        }
        return GitHubDeviceCode(deviceCode: device, userCode: user,
                                expiresAt: Date().addingTimeInterval(expires),
                                interval: max(5, response.interval ?? 5))
    }

    func finishDeviceLogin(_ code: GitHubDeviceCode) async throws -> String {
        var interval = code.interval
        while Date() < code.expiresAt {
            try Task.checkCancellation()
            try await pause(min(interval, max(0, code.expiresAt.timeIntervalSinceNow)))
            try Task.checkCancellation()
            guard Date() < code.expiresAt else { throw GitHubDeviceFlowError.expired }
            let response: GitHubOAuthResponse = try await oauthRequest(path: "oauth/access_token", parameters: [
                "client_id": Self.clientID, "device_code": code.deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
            switch response.error {
            case "authorization_pending": continue
            case "slow_down": interval = max(interval + 5, response.interval ?? 0)
            case "expired_token", "token_expired": throw GitHubDeviceFlowError.expired
            case "access_denied": throw GitHubDeviceFlowError.denied
            case "device_flow_disabled": throw GitHubDeviceFlowError.disabled
            case "incorrect_client_credentials": throw GitHubDeviceFlowError.client
            case nil:
                guard Date() < code.expiresAt else { throw GitHubDeviceFlowError.expired }
                let credential = try await validatedCredential(response)
                try Task.checkCancellation()
                try store.save(credential)
                return credential.login
            default: throw GitHubDeviceFlowError.response
            }
        }
        throw GitHubDeviceFlowError.expired
    }

    /// Shared by all windows so rotating a refresh token is a single operation.
    func validCredential() async throws -> GitHubCredential? {
        guard let credential = try store.read() else { return nil }
        guard let expiration = credential.expiresAt,
              expiration <= Date().addingTimeInterval(60) else { return credential }
        if let refreshTask { return try await refreshTask.value }
        let task = Task { try await self.refresh(credential) }
        refreshTask = task
        defer { refreshTask = nil }
        return try await task.value
    }

    private func refresh(_ old: GitHubCredential) async throws -> GitHubCredential {
        guard let refreshToken = old.refreshToken,
              old.refreshExpiresAt.map({ $0 > Date() }) ?? true else {
            throw GitHubDeviceFlowError.signInAgain
        }
        let response: GitHubOAuthResponse = try await oauthRequest(path: "oauth/access_token", parameters: [
            "client_id": Self.clientID, "grant_type": "refresh_token", "refresh_token": refreshToken
        ])
        guard response.error == nil else { throw GitHubDeviceFlowError.signInAgain }
        let replacement = try await validatedCredential(response)
        try Task.checkCancellation()
        // Never restore an account disconnected or replaced while HTTP was in flight.
        guard try store.read()?.token == old.token else { throw CancellationError() }
        guard replacement.login == old.login else { throw GitHubDeviceFlowError.signInAgain }
        try store.save(replacement)
        return replacement
    }

    private func validatedCredential(_ response: GitHubOAuthResponse) async throws -> GitHubCredential {
        guard let token = response.accessToken, !token.isEmpty,
              response.tokenType?.lowercased() == "bearer" else { throw GitHubDeviceFlowError.response }
        let issued = Date()
        let login = try await validate(token: token)
        return GitHubCredential(login: login, token: token,
                                expiresAt: response.expiresIn.map { issued.addingTimeInterval($0) },
                                refreshToken: response.refreshToken,
                                refreshExpiresAt: response.refreshTokenExpiresIn.map { issued.addingTimeInterval($0) })
    }

    private func oauthRequest<T: Decodable>(path: String, parameters: [String: String]) async throws -> T {
        var request = URLRequest(url: URL(string: "https://github.com/login/\(path)")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("TypeNBash", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(parameters)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw GitHubAuthenticationError.network
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse,
              ((200..<300).contains(http.statusCode) || http.statusCode == 400) else { throw GitHubDeviceFlowError.response }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let result = try? decoder.decode(T.self, from: data) else { throw GitHubDeviceFlowError.response }
        return result
    }
}
