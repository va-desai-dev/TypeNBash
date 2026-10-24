import Foundation

/// Chat Completions streams tool calls by index, with names and JSON arguments
/// split across deltas. Never expose an executable call until the stream finishes.
nonisolated struct AgentChatCompletionStream {
    private var text = ""
    private var reasoning: [String: String] = [:]
    private var calls: [Int: AgentJSON] = [:]
    private var stopReason: String?
    private var inputTokens = 0
    private var outputTokens = 0
    private(set) var isComplete = false

    mutating func consume(_ data: Data) throws -> String {
        guard !isComplete else { throw AgentFailure("Unexpected data after completion.") }
        if data == Data("[DONE]".utf8) {
            guard stopReason != nil else { throw AgentFailure("Chat stream ended without a finish reason.") }
            isComplete = true
            return ""
        }
        let event = try JSONDecoder().decode(AgentJSON.self, from: data)
        guard event["error"] == .null else { throw AgentFailure("The model server returned an error; no partial calls were executed.") }
        inputTokens = event["usage"]["prompt_tokens"].integer ?? inputTokens
        outputTokens = event["usage"]["completion_tokens"].integer ?? outputTokens
        let choices = event["choices"].array
        // A usage-only final chunk has no choices.
        guard !choices.isEmpty else { return "" }
        guard choices.count == 1, choices[0]["index"].integer == 0, stopReason == nil else {
            throw AgentFailure("Unexpected chat completion choice or trailing delta.")
        }
        let choice = choices[0], delta = choice["delta"]
        let added = (delta["content"].string ?? "") + (delta["refusal"].string ?? "")
        text += added
        for field in ["reasoning_content", "reasoning"] {
            if let value = delta[field].string { reasoning[field, default: ""] += value }
        }
        for fragment in delta["tool_calls"].array {
            guard let index = fragment["index"].integer, (0..<32).contains(index),
                  fragment["type"] == .null || fragment["type"].string == "function" else {
                throw AgentFailure("Invalid streamed tool call.")
            }
            var call = calls[index] ?? .object(["id": .string(""), "type": .string("function"),
                "function": .object(["name": .string(""), "arguments": .string("")])])
            if let id = fragment["id"].string, !id.isEmpty {
                guard call["id"].string == "" || call["id"].string == id else { throw AgentFailure("Tool call ID changed while streaming.") }
                call = call.setting("id", .string(id))
            }
            var function = call["function"]
            for field in ["name", "arguments"] {
                if let value = fragment["function"][field].string {
                    function = function.setting(field, .string((function[field].string ?? "") + value))
                }
            }
            calls[index] = call.setting("function", function)
        }
        if let reason = choice["finish_reason"].string {
            guard ["stop", "tool_calls"].contains(reason) else {
                throw AgentFailure("The model stopped before completing its response (\(reason)); no partial calls were executed.")
            }
            stopReason = reason
        }
        return added
    }

    func finish() throws -> AgentResponse {
        guard isComplete, let stopReason, (calls.isEmpty ? stopReason == "stop" : stopReason == "tool_calls") else {
            throw AgentFailure("Chat stream ended early or with inconsistent tool calls. No partial calls were executed.")
        }
        let rawCalls = calls.keys.sorted().compactMap { calls[$0] }
        let completed = try rawCalls.map { call -> AgentToolCall in
            guard let id = call["id"].string, !id.isEmpty, let name = call["function"]["name"].string, !name.isEmpty,
                  let raw = call["function"]["arguments"].string else { throw AgentFailure("Malformed chat tool call.") }
            let arguments = try JSONDecoder().decode(AgentJSON.self, from: Data(raw.utf8))
            guard case .object = arguments else { throw AgentFailure("Tool arguments must be an object.") }
            return .init(id: id, name: name, arguments: arguments)
        }
        guard Set(completed.map(\.id)).count == completed.count else { throw AgentFailure("Duplicate tool call IDs.") }
        var message = AgentJSON.object(["role": .string("assistant"), "content": .string(text)])
        if !rawCalls.isEmpty { message = message.setting("tool_calls", .array(rawCalls)) }
        for (field, value) in reasoning { message = message.setting(field, .string(value)) }
        return .init(items: [message], text: text, calls: completed, inputTokens: inputTokens, outputTokens: outputTokens)
    }
}
