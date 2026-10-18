import Foundation

nonisolated enum AgentJSON: Codable, Equatable, Sendable {
    case object([String: AgentJSON]), array([AgentJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([AgentJSON].self) { self = .array(v) }
        else { self = .object(try c.decode([String: AgentJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }

    subscript(_ key: String) -> AgentJSON { object[key] ?? .null }
    var object: [String: AgentJSON] { if case .object(let v) = self { v } else { [:] } }
    var array: [AgentJSON] { if case .array(let v) = self { v } else { [] } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
    var integer: Int? {
        guard case .number(let v) = self, v.isFinite, v >= -1_000_000_000, v <= 1_000_000_000,
              v.rounded() == v else { return nil }
        return Int(v)
    }
    var encoded: String { String(decoding: (try? JSONEncoder().encode(self)) ?? Data(), as: UTF8.self) }
    func setting(_ key: String, _ value: AgentJSON) -> AgentJSON {
        var copy = object; copy[key] = value; return .object(copy)
    }
}

nonisolated struct AgentFailure: LocalizedError, Sendable {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

nonisolated enum AgentProviderKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case chatCompletions, openAI, anthropic
    var id: Self { self }
    var title: String {
        switch self {
        case .chatCompletions: "OpenAI Chat Completions"
        case .openAI: "OpenAI Responses"
        case .anthropic: "Anthropic Messages"
        }
    }
    var endpointPath: String {
        switch self {
        case .chatCompletions: "chat/completions"
        case .openAI: "responses"
        case .anthropic: "messages"
        }
    }
}

nonisolated enum AgentPermissionMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case ask, edit
    var id: Self { self }
    var title: String { self == .ask ? "Ask before edits" : "Allow workspace edits" }
    var systemImage: String { self == .ask ? "hand.raised" : "pencil" }
}

nonisolated struct AgentToolCall: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let arguments: AgentJSON
}

nonisolated struct AgentToolResult: Codable, Equatable, Sendable {
    let id: String
    let output: String
    var isError = false
}

nonisolated struct AgentToolDefinition: Sendable {
    let name: String
    let description: String
    let properties: [String: AgentJSON]
    var schema: AgentJSON {
        .object(["type": .string("object"), "properties": .object(properties),
                 "required": .array(properties.keys.sorted().map(AgentJSON.string)), "additionalProperties": .bool(false)])
    }
}

nonisolated struct AgentResponse: Sendable {
    var items: [AgentJSON]
    var text: String
    var calls: [AgentToolCall]
    var inputTokens = 0
    var outputTokens = 0
}

nonisolated protocol AgentProvider: Sendable {
    var kind: AgentProviderKind { get }
    func respond(history: [AgentJSON], tools: [AgentToolDefinition],
                 onText: @escaping @Sendable (String) async -> Void) async throws -> AgentResponse
}

extension AgentProviderKind {
    nonisolated func userMessage(_ text: String) -> AgentJSON {
        .object(["role": .string("user"), "content": .string(text)])
    }

    nonisolated func resultMessages(_ results: [AgentToolResult]) -> [AgentJSON] {
        if self == .chatCompletions {
            return results.map {
                .object(["role": .string("tool"), "tool_call_id": .string($0.id),
                         "content": .string($0.isError ? "ERROR: " + $0.output : $0.output)])
            }
        }
        if self == .anthropic {
            return [.object(["role": .string("user"), "content": .array(results.map {
                .object(["type": .string("tool_result"), "tool_use_id": .string($0.id),
                         "content": .string($0.output), "is_error": .bool($0.isError)])
            })])]
        }
        return results.map {
            .object(["type": .string("function_call_output"), "call_id": .string($0.id),
                     "output": .string($0.isError ? "ERROR: " + $0.output : $0.output)])
        }
    }
}

nonisolated enum AgentBuildCapabilities {
    static var localCommands: Bool {
        #if DIRECT_DISTRIBUTION && !APP_STORE
        true
        #else
        false
        #endif
    }
}
