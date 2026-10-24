import Foundation
import Observation
import Security

nonisolated struct AgentCredentialStore {
    var service = "com.TypeNBash.agent-api-keys"
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> String? {
        var q = query(account)
        q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw AgentFailure("Cannot read the credential from Keychain (\(status)).")
        }
        return value
    }
    func save(_ key: String, for account: String) throws {
        let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !key.contains(where: \.isWhitespace) else { throw AgentFailure("Enter a credential without spaces or line breaks.") }
        let value: [String: Any] = [kSecValueData as String: Data(key.utf8)]
        var status = SecItemUpdate(query(account) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var q = query(account).merging(value) { _, new in new }
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            status = SecItemAdd(q as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw AgentFailure("Cannot save credential (\(status)).") }
    }
    func delete(_ account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw AgentFailure("Cannot remove credential (\(status)).") }
    }
}

@MainActor @Observable
final class AgentSettings {
    static let shared = AgentSettings()
    private let defaults: UserDefaults
    private let credentials: AgentCredentialStore
    private var connections: [String: AgentConnection]
    var preset: AgentConnectionPreset {
        didSet { defaults.set(preset.rawValue, forKey: "agent.connection.preset"); refresh() }
    }
    var connection: AgentConnection {
        get { connections[preset.rawValue] ?? preset.connection }
        set {
            let previous = connection
            connections[preset.rawValue] = newValue
            // Keep invalid URL drafts in memory, not persisted with embedded secrets.
            if (try? newValue.apiBaseURL()) != nil,
               let data = try? JSONEncoder().encode(connections.filter { (try? $0.value.apiBaseURL()) != nil }) {
                defaults.set(data, forKey: "agent.connections")
            }
            if previous.baseURL != newValue.baseURL || previous.authentication != newValue.authentication { refresh() }
        }
    }
    var apiKey = ""
    private(set) var status = ""
    private(set) var hasKey = false
    var endpointDescription: String { (try? connection.endpoint().absoluteString) ?? "Enter a valid Base URL." }

    init(defaults: UserDefaults = .standard, credentials: AgentCredentialStore = .init()) {
        self.defaults = defaults; self.credentials = credentials
        connections = defaults.data(forKey: "agent.connections")
            .flatMap { try? JSONDecoder().decode([String: AgentConnection].self, from: $0) } ?? [:]
        preset = AgentConnectionPreset(rawValue: defaults.string(forKey: "agent.connection.preset") ?? "")
            ?? AgentConnectionPreset(rawValue: defaults.string(forKey: "agent.provider") ?? "") ?? .engrai
        for (preset, key) in [(AgentConnectionPreset.openAI, "agent.openai.model"), (.anthropic, "agent.anthropic.model")] {
            if connections[preset.rawValue] == nil, let model = defaults.string(forKey: key) {
                var connection = preset.connection; connection.model = model
                connections[preset.rawValue] = connection
            }
        }
    }
    func refresh() {
        apiKey = ""; status = ""; hasKey = false
        guard connection.authentication != .none else { return }
        do { hasKey = try credentials.read(connection.credentialAccount()) != nil }
        catch { status = error.localizedDescription }
    }
    func saveKey() {
        do {
            try credentials.save(apiKey, for: connection.credentialAccount())
            apiKey = ""; hasKey = true; status = "Credential saved in Keychain for this endpoint."
        } catch { status = error.localizedDescription }
    }
    func forgetKey() {
        do { try credentials.delete(connection.credentialAccount()); apiKey = ""; hasKey = false; status = "Credential removed." }
        catch { status = error.localizedDescription }
    }
    func makeProvider(connection: AgentConnection) throws -> AgentHTTPProvider {
        let key = connection.authentication == .none ? "" : try credentials.read(connection.credentialAccount()) ?? ""
        let provider = AgentHTTPProvider(connection: connection, key: key)
        _ = try provider.request(history: [], tools: [])
        return provider
    }
}
