import Foundation
import CryptoKit

nonisolated enum AgentAuthentication: String, Codable, CaseIterable, Identifiable, Sendable {
    case none, bearer, anthropicKey
    var id: Self { self }
    var title: String {
        switch self {
        case .none: "None"
        case .bearer: "Bearer credential"
        case .anthropicKey: "Anthropic API key"
        }
    }
}

/// Presets are independent saved connections. The API format describes the wire
/// protocol, not the vendor running the model.
nonisolated enum AgentConnectionPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case engrai, ollama, ollamaCloud, openAI, anthropic
    var id: Self { self }
    var title: String {
        switch self {
        case .engrai: "ENGRAISERVER / Custom"
        case .ollama: "Ollama"
        case .ollamaCloud: "Ollama Cloud"
        case .openAI: "OpenAI API"
        case .anthropic: "Anthropic API"
        }
    }
    var connection: AgentConnection {
        switch self {
        case .engrai: .init(name: title, kind: .chatCompletions, baseURL: "https://llm.engrai.app/v1", authentication: .bearer)
        case .ollama: .init(name: title, kind: .openAI, baseURL: "http://localhost:11434/v1", authentication: .none)
        case .ollamaCloud: .init(name: title, kind: .openAI, baseURL: "https://ollama.com/v1", authentication: .bearer)
        case .openAI: .init(name: title, kind: .openAI, baseURL: "https://api.openai.com/v1", authentication: .bearer)
        case .anthropic: .init(name: title, kind: .anthropic, baseURL: "https://api.anthropic.com/v1", authentication: .anthropicKey)
        }
    }
}

nonisolated struct AgentConnection: Codable, Equatable, Sendable {
    var name: String
    var kind: AgentProviderKind
    var baseURL: String
    var authentication: AgentAuthentication
    var model = ""

    /// Accept an origin or API base path; also normalize a pasted full endpoint.
    /// Query strings and embedded credentials never enter persisted requests.
    func apiBaseURL() throws -> URL {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var parts = URLComponents(string: raw), let scheme = parts.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let host = parts.host?.lowercased(), !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              !raw.contains(where: \.isWhitespace), parts.port.map({ (1...65535).contains($0) }) ?? true else {
            throw AgentFailure("Enter an HTTP or HTTPS Base URL without credentials, a query, or a fragment.")
        }
        guard scheme == "https" || Self.isLocalHost(host) else {
            throw AgentFailure("Use HTTPS for remote servers. HTTP is supported for local model servers.")
        }
        parts.scheme = scheme; parts.host = host
        if (scheme == "https" && parts.port == 443) || (scheme == "http" && parts.port == 80) { parts.port = nil }
        var path = parts.path
        while path.hasSuffix("/") { path.removeLast() }
        for suffix in ["/chat/completions", "/responses", "/messages"] where path.hasSuffix(suffix) {
            path.removeLast(suffix.count)
            break
        }
        if path.isEmpty { path = "/v1" }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw AgentFailure("The API base path cannot contain traversal components.")
        }
        parts.path = path
        guard let url = parts.url else { throw AgentFailure("Invalid Base URL.") }
        return url
    }

    func endpoint() throws -> URL { try apiBaseURL().appendingPathComponent(kind.endpointPath) }

    /// Keep old official-provider keys usable, while custom keys are scoped to
    /// the exact normalized API base and authentication mode.
    func credentialAccount() throws -> String {
        let base = try apiBaseURL().absoluteString
        if base == "https://api.openai.com/v1", authentication == .bearer { return "openAI" }
        if base == "https://api.anthropic.com/v1", authentication == .anthropicKey { return "anthropic" }
        let hash = SHA256.hash(data: Data((base + "|" + authentication.rawValue).utf8))
        return "endpoint-" + hash.map { String(format: "%02x", $0) }.joined()
    }

    var usesOpenAIExtensions: Bool {
        kind == .openAI && (try? apiBaseURL().absoluteString) == "https://api.openai.com/v1"
    }

    private static func isLocalHost(_ host: String) -> Bool {
        if host == "localhost" || host.hasSuffix(".localhost") || host.hasSuffix(".local") { return true }
        let bare = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if bare == "::1" || bare.hasPrefix("fc") && bare.contains(":") || bare.hasPrefix("fd") && bare.contains(":") || bare.hasPrefix("fe80:") { return true }
        let octets = host.split(separator: ".").compactMap { UInt8($0) }
        if octets.count == 4 {
            return octets[0] == 127 || octets[0] == 10 || octets[0] == 192 && octets[1] == 168
                || octets[0] == 172 && (16...31).contains(octets[1]) || octets[0] == 169 && octets[1] == 254
        }
        return !host.contains(".") && !host.contains(":")
    }
}
