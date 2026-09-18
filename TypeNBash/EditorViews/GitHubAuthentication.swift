import Foundation
import Observation
import Security
import AppKit

nonisolated struct GitHubCredential: Codable, Sendable {
    let login: String
    let token: String
    var expiresAt: Date? = nil
    var refreshToken: String? = nil
    var refreshExpiresAt: Date? = nil
}

/// One GitHub.com account, kept entirely in Keychain (including its token).
nonisolated struct GitHubCredentialStore: Sendable {
    var service = "com.TypeNBash.github.authentication"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: "github.com"]
    }

    func read() throws -> GitHubCredential? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw GitHubAuthenticationError.keychain(status)
        }
        return try JSONDecoder().decode(GitHubCredential.self, from: data)
    }

    func save(_ credential: GitHubCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let values: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, values as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = query.merging(values) { _, new in new }
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(attributes as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw GitHubAuthenticationError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw GitHubAuthenticationError.keychain(status)
        }
    }
}

nonisolated enum GitHubAuthenticationError: LocalizedError {
    case invalidToken, denied, network, invalidResponse, keychain(OSStatus), transport, unsafeRemote
    var errorDescription: String? {
        switch self {
        case .invalidToken: "GitHub rejected this token. Check that it is valid and has not expired."
        case .denied: "GitHub denied access. Check token permissions, organization approval, and API rate limits."
        case .network: "Couldn’t reach GitHub securely. Check your connection and try again."
        case .invalidResponse: "GitHub returned an unexpected response. Try again later."
        case .keychain(let status): "Couldn’t access the GitHub credential in Keychain (\(status))."
        case .transport: "Fetch failed. Check the remote URL, connection, token expiry, repository Contents permission, and any required organization approval."
        case .unsafeRemote: "Token authentication requires an HTTPS remote on github.com without credentials in its URL."
        }
    }
}

/// Never forward the Authorization header through an API redirect.
nonisolated final class GitHubRedirectPolicy: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

actor GitHubAuthenticationService {
    static let shared = GitHubAuthenticationService()
    let store: GitHubCredentialStore
    let session: URLSession
    let pause: @Sendable (TimeInterval) async throws -> Void
    var refreshTask: Task<GitHubCredential, Error>?

    init(store: GitHubCredentialStore = GitHubCredentialStore(), session: URLSession? = nil,
         pause: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
             try await Task.sleep(for: .seconds(seconds))
         }) {
        self.pause = pause
        self.store = store
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 45
        self.session = session ?? URLSession(configuration: configuration,
                                             delegate: GitHubRedirectPolicy(), delegateQueue: nil)
    }

    func savedLogin() throws -> String? { try store.read()?.login }
    func disconnect() throws {
        refreshTask?.cancel()
        try store.delete()
    }

    func connect(token: String) async throws -> String {
        let login = try await validate(token: token)
        try Task.checkCancellation()
        try store.save(GitHubCredential(login: login, token: token.trimmingCharacters(in: .whitespacesAndNewlines)))
        return login
    }

    func validate(token: String) async throws -> String {
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw GitHubAuthenticationError.invalidToken
        }
        var request = URLRequest(url: URL(string: "https://api.github.com/user")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.setValue("TypeNBash", forHTTPHeaderField: "User-Agent")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch {
            try Task.checkCancellation()
            throw GitHubAuthenticationError.network
        }
        guard let http = response as? HTTPURLResponse else { throw GitHubAuthenticationError.invalidResponse }
        switch http.statusCode {
        case 200: break
        case 401: throw GitHubAuthenticationError.invalidToken
        case 403, 429: throw GitHubAuthenticationError.denied
        default: throw GitHubAuthenticationError.invalidResponse
        }
        struct User: Decodable { let login: String; let id: Int }
        guard let user = try? JSONDecoder().decode(User.self, from: data),
              !user.login.isEmpty, user.id > 0 else { throw GitHubAuthenticationError.invalidResponse }
        try Task.checkCancellation()
        return user.login
    }
}

@MainActor
@Observable
final class GitHubAccountModel {
    private let service = GitHubAuthenticationService.shared
    private var loginTask: Task<Void, Never>?
    private var generation = 0
    private(set) var userCode: String?
    private(set) var login: String?
    private(set) var isBusy = false
    private(set) var errorMessage: String?

    func load() async {
        guard !isBusy else { return }
        let request = generation
        do {
            let saved = try await service.savedLogin()
            if request == generation { login = saved }
        } catch {
            if request == generation { errorMessage = error.localizedDescription }
        }
    }

    func connect() {
        guard !isBusy else { return }
        generation &+= 1
        let request = generation
        isBusy = true
        errorMessage = nil
        loginTask = Task {
            defer {
                if generation == request {
                    isBusy = false
                    userCode = nil
                    loginTask = nil
                }
            }
            do {
                let code = try await service.beginDeviceLogin()
                try Task.checkCancellation()
                guard generation == request else { return }
                userCode = code.userCode
                openBrowser()
                let account = try await service.finishDeviceLogin(code)
                try Task.checkCancellation()
                if generation == request { login = account }
            } catch is CancellationError {
                // A cancelled or replaced flow cannot publish an account or error.
            } catch {
                if generation == request { errorMessage = error.localizedDescription }
            }
        }
    }

    func openBrowser() {
        NSWorkspace.shared.open(URL(string: "https://github.com/login/device")!)
    }

    func copyCode() {
        guard let userCode else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(userCode, forType: .string)
    }

    func cancel() {
        guard loginTask != nil else { return }
        generation &+= 1
        loginTask?.cancel()
        loginTask = nil
        isBusy = false
        userCode = nil
    }

    func disconnect() async {
        guard !isBusy else { return }
        generation &+= 1
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await service.disconnect()
            login = nil
        } catch { errorMessage = error.localizedDescription }
    }
}
