import Foundation
import Observation

/// App-owned defaults remain accessible inside the App Store sandbox.
@MainActor @Observable
final class SourceControlIdentitySettings {
    static let shared = SourceControlIdentitySettings()
    private let defaults: UserDefaults
    private static let key = "sourceControl.defaultIdentity"
    private(set) var identity: SourceControlIdentity?
    var draft: SourceControlIdentity
    private(set) var errorMessage: String?
    var canSave: Bool { (try? draft.validated()) != nil && draft != identity }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.dictionary(forKey: Self.key)
        let value = SourceControlIdentity(name: saved?["name"] as? String ?? "",
                                          email: saved?["email"] as? String ?? "")
        let valid = try? value.validated()
        identity = valid
        draft = valid ?? SourceControlIdentity()
    }

    func setIdentity(_ value: SourceControlIdentity) throws {
        let value = try value.validated()
        defaults.set(["name": value.name, "email": value.email], forKey: Self.key)
        identity = value
        draft = value
        errorMessage = nil
    }

    func save() {
        do { try setIdentity(draft) }
        catch { errorMessage = error.localizedDescription }
    }

    func clear() {
        defaults.removeObject(forKey: Self.key)
        identity = nil
        draft = SourceControlIdentity()
        errorMessage = nil
    }
}
