import Foundation

/// One step of an agent turn, independent of the CLI that produced it.
enum AgentEvent: Equatable {
    case started(sessionID: String)
    case textDelta(String)
    case reasoningDelta(String)
    /// A finished content block. It supersedes whatever streamed for it.
    case block(TranscriptBlock)
    case toolResult(toolID: String, output: String, isError: Bool)
    case finished(AgentTurnSummary)
}

struct AgentTurnSummary: Equatable {
    let sessionID: String?
    let isError: Bool
    /// The final reply, or the failure reason when `isError`.
    let message: String
    let turns: Int
    let duration: Duration
}

/// Decodes `claude --print --output-format stream-json` lines. Subagent traffic
/// (a non-null `parent_tool_use_id`) is skipped so the transcript follows the
/// top-level conversation; unknown event types are ignored.
enum ClaudeCodeStream {
    /// Tool output is for glancing at, not archiving; a full file read would
    /// otherwise sit in the transcript.
    static let outputLimit = 20_000

    static func events(from line: Data) -> [AgentEvent] {
        guard let event = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              event["parent_tool_use_id"] == nil || event["parent_tool_use_id"] is NSNull
        else { return [] }
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []

        switch event["type"] as? String {
        case "system" where event["subtype"] as? String == "init":
            return (event["session_id"] as? String).map { [.started(sessionID: $0)] } ?? []

        case "stream_event":
            let delta = (event["event"] as? [String: Any])?["delta"] as? [String: Any]
            switch delta?["type"] as? String {
            case "text_delta": return [.textDelta(delta?["text"] as? String ?? "")]
            case "thinking_delta": return [.reasoningDelta(delta?["thinking"] as? String ?? "")]
            default: return []
            }

        case "assistant":
            return content.compactMap { part in
                switch part["type"] as? String {
                case "text":
                    let text = part["text"] as? String ?? ""
                    return text.isEmpty ? nil : .block(TranscriptBlock(kind: .text(text)))
                case "thinking":
                    // Signed-only thinking arrives empty; the live indicator covered it.
                    let text = part["thinking"] as? String ?? ""
                    return text.isEmpty ? nil : .block(TranscriptBlock(kind: .reasoning(text)))
                case "tool_use":
                    guard let id = part["id"] as? String else { return nil }
                    let input = part["input"] as? [String: Any] ?? [:]
                    let detail = ["command", "file_path", "notebook_path", "pattern", "url", "query", "description"]
                        .lazy.compactMap { input[$0] as? String }.first { !$0.isEmpty } ?? ""
                    let tool = ToolActivity(name: part["name"] as? String ?? "Tool", detail: detail)
                    return .block(TranscriptBlock(id: id, kind: .tool(tool)))
                default:
                    return nil
                }
            }

        case "user":
            return content.compactMap { part in
                guard part["type"] as? String == "tool_result",
                      let id = part["tool_use_id"] as? String else { return nil }
                let output: String
                if let parts = part["content"] as? [[String: Any]] {
                    output = parts.map { $0["text"] as? String ?? "[\($0["type"] as? String ?? "content")]" }
                        .joined(separator: "\n")
                } else {
                    output = part["content"] as? String ?? ""
                }
                return .toolResult(toolID: id, output: String(output.prefix(outputLimit)),
                                   isError: part["is_error"] as? Bool ?? false)
            }

        case "result":
            let isError = event["is_error"] as? Bool ?? (event["subtype"] as? String != "success")
            let errors = (event["errors"] as? [String])?.joined(separator: "\n")
            let message = event["result"] as? String ?? errors ?? event["subtype"] as? String ?? ""
            return [.finished(AgentTurnSummary(
                sessionID: event["session_id"] as? String,
                isError: isError,
                message: message,
                turns: event["num_turns"] as? Int ?? 0,
                duration: .milliseconds(event["duration_ms"] as? Int ?? 0)
            ))]

        default:
            return []
        }
    }
}
