import Foundation

nonisolated struct AgentConversation: Codable, Sendable {
    var history: [AgentJSON] = []
    var pending: [AgentToolCall] = []
    var results: [AgentToolResult] = []

    mutating func settlePending(provider: AgentProviderKind) {
        guard !pending.isEmpty else { return }
        let completed = Set(results.map(\.id))
        results += pending.filter { !completed.contains($0.id) }.map {
            AgentToolResult(id: $0.id, output: "Interrupted. Execution may not have completed; inspect current state before trying again.", isError: true)
        }
        history += provider.resultMessages(results)
        pending = []; results = []
    }
}

nonisolated enum AgentRunEvent: Sendable {
    case delta(String), response(String), tool(AgentToolCall), result(AgentToolResult)
    case usage(input: Int, output: Int)
    case checkpoint(AgentConversation)
}

/// Owns provider turns. Tool permission decisions and execution are injected,
/// so neither a provider adapter nor model-generated arguments can grant access.
actor AgentRunner {
    private let provider: any AgentProvider
    private let definitions: [AgentToolDefinition]
    private var conversation: AgentConversation
    private var running = false
    let maximumRounds: Int

    init(provider: any AgentProvider, tools: [AgentToolDefinition], conversation: AgentConversation = .init(), maximumRounds: Int = 20) {
        self.provider = provider; definitions = tools
        var restored = conversation
        restored.settlePending(provider: provider.kind)
        self.conversation = restored
        self.maximumRounds = maximumRounds
    }

    func run(_ prompt: String,
             execute: @escaping @Sendable (AgentToolCall) async throws -> AgentToolResult,
             emit: @escaping @Sendable (AgentRunEvent) async -> Void) async throws {
        guard !running else { throw AgentFailure("A turn is already running.") }
        running = true
        defer { running = false }
        conversation.history.append(provider.kind.userMessage(prompt))
        await emit(.checkpoint(conversation))
        do {
            for _ in 0..<maximumRounds {
                try Task.checkCancellation()
                guard try JSONEncoder().encode(conversation).count < 2_000_000 else {
                    throw AgentFailure("Conversation reached its context limit. Start a new conversation.")
                }
                let response = try await provider.respond(history: conversation.history, tools: definitions) { text in
                    await emit(.delta(text))
                }
                try Task.checkCancellation()
                conversation.history += response.items
                conversation.pending = response.calls
                await emit(.response(response.text))
                await emit(.usage(input: response.inputTokens, output: response.outputTokens))
                await emit(.checkpoint(conversation))
                if response.calls.isEmpty { return }
                for call in response.calls {
                    try Task.checkCancellation()
                    await emit(.tool(call))
                    let result: AgentToolResult
                    do {
                        guard let definition = definitions.first(where: { $0.name == call.name }),
                              Set(call.arguments.object.keys) == Set(definition.properties.keys) else {
                            throw AgentFailure("Unavailable tool or invalid arguments: \(call.name).")
                        }
                        result = try await execute(call)
                    } catch is CancellationError { throw CancellationError() }
                    catch { result = AgentToolResult(id: call.id, output: error.localizedDescription, isError: true) }
                    // Journal immediately after execution, before starting another tool.
                    conversation.results.append(result)
                    await emit(.result(result))
                    await emit(.checkpoint(conversation))
                }
                conversation.settlePending(provider: provider.kind)
                await emit(.checkpoint(conversation))
            }
            throw AgentFailure("Stopped after \(maximumRounds) model rounds. Send a follow-up to continue.")
        } catch {
            let finished = Set(conversation.results.map(\.id))
            for call in conversation.pending where !finished.contains(call.id) {
                await emit(.result(.init(id: call.id, output: "Interrupted; inspect current state before retrying.", isError: true)))
            }
            conversation.settlePending(provider: provider.kind)
            await emit(.checkpoint(conversation))
            throw error
        }
    }
}
