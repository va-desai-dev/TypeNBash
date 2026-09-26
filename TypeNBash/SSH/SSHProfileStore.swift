import Foundation
import Observation
import Security

/// Persists reusable SSH connection profiles so a login only has to be entered
/// once. Connection details live in UserDefaults; passwords (if the user opts in)
/// live in the Keychain and never touch the codable profile.
@MainActor
@Observable
final class SSHProfileStore {
    /// The app-wide store. Every window and the Settings window share it, since
    /// each store writes its whole list back and a second copy would overwrite
    /// changes made through the first.
    static let shared = SSHProfileStore()

    private(set) var profiles: [SSHConnectionProfile]

    private let defaults: UserDefaults
    private let storageKey = "TypeNBash.ssh.profiles"
    private let keychainService = "com.TypeNBash.ssh.password"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([SSHConnectionProfile].self, from: data) {
            profiles = decoded
        } else {
            profiles = []
        }
    }

    /// Inserts or updates the profile (matched by id) and, when provided, stores
    /// the password in the Keychain. Passing `password: nil` clears any saved one.
    func save(_ profile: SSHConnectionProfile, password: String?) {
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
        setPassword(password, for: profile.id)
    }

    /// Updates the connection details of an existing profile without touching
    /// its saved password.
    func update(_ profile: SSHConnectionProfile) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        profiles[index] = profile
        persist()
    }

    /// Removes the saved password, leaving the profile to use key or agent auth.
    func forgetPassword(for id: UUID) {
        setPassword(nil, for: id)
    }

    func delete(_ profile: SSHConnectionProfile) {
        profiles.removeAll { $0.id == profile.id }
        persist()
        setPassword(nil, for: profile.id)
    }

    /// Whether a password is saved, checked without reading the secret itself.
    func hasPassword(for id: UUID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func password(for id: UUID) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(profiles) else { return }
        defaults.set(data, forKey: storageKey)
    }

    /// Best effort — if the Keychain is unavailable (e.g. missing entitlement),
    /// the connection details are still saved and only the password is skipped.
    private func setPassword(_ password: String?, for id: UUID) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecAttrAccount as String: id.uuidString
        ]
        SecItemDelete(base as CFDictionary)

        guard let password, let data = password.data(using: .utf8) else { return }
        var attributes = base
        attributes[kSecValueData as String] = data
        SecItemAdd(attributes as CFDictionary, nil)
    }
}
