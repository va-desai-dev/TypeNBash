import Foundation
@testable import TypeNBash

/// Drives `AgentSession` against a stand-in `claude` script that replays a
/// stream-json turn trimmed from a real Claude Code 2.1 run. No account,
/// network, or installed CLI is involved.
@main
struct AgentIntegrationChecks {
    static let fixture = [
        #"{"type":"system","subtype":"init","session_id":"S1","cwd":"/elsewhere","permissionMode":"acceptEdits"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"input_json_delta","partial_json":"{\"command\": \"pwd"}},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"id":"m1","role":"assistant","content":[{"type":"tool_use","id":"toolu_1","name":"Bash","input":{"command":"pwd","description":"Print working directory"}}]},"parent_tool_use_id":null,"session_id":"S1"}"#,
        #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"S1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_1","type":"tool_result","content":"/project","is_error":false}]},"parent_tool_use_id":null,"session_id":"S1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"","estimated_tokens":50}},"parent_tool_use_id":null}"#,
        #"{"type":"assistant","message":{"id":"m2","role":"assistant","content":[{"type":"thinking","thinking":"","signature":"sig"}]},"parent_tool_use_id":null,"session_id":"S1"}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"Hel"}},"parent_tool_use_id":null}"#,
        #"{"type":"stream_event","event":{"type":"content_block_delta","index":1,"delta":{"type":"text_delta","text":"lo"}},"parent_tool_use_id":null}"#,
        "{\"type\":\"assistant\",\"message\":{\"id\":\"m2\",\"role\":\"assistant\",\"content\":[{\"type\":\"text\",\"text\":\"Hello\u{2028}world\"}]},\"parent_tool_use_id\":null,\"session_id\":\"S1\"}",
        #"{"type":"assistant","message":{"id":"m3","role":"assistant","content":[{"type":"text","text":"subagent chatter"}]},"parent_tool_use_id":"toolu_task","session_id":"S1"}"#,
        #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_2","type":"tool_result","content":[{"type":"text","text":"line"},{"type":"image"}],"is_error":true}]},"parent_tool_use_id":null}"#,
        #"{"type":"result","subtype":"success","is_error":false,"result":"Hello","session_id":"S1","num_turns":2,"duration_ms":6111}"#
    ]

    @MainActor static func main() async throws {
        setbuf(stdout, nil)
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("agent-checks-\(UUID())").resolvingSymlinksInPath()
        let project = root.appendingPathComponent("Project café")
        let log = root.appendingPathComponent("log")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        try fm.createDirectory(at: log, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }

        // Decoder
        let events = fixture.flatMap { ClaudeCodeStream.events(from: Data($0.utf8)) }
        check(events.first == .started(sessionID: "S1"), "Init reports the CLI session id")
        check(events.contains(.textDelta("Hel")) && events.contains(.reasoningDelta("")),
              "Text and thinking deltas stream; tool input deltas are ignored")
        let blocks = events.compactMap { event -> TranscriptBlock.Kind? in
            if case .block(let block) = event { return block.kind } else { return nil }
        }
        check(blocks == [.tool(ToolActivity(name: "Bash", detail: "pwd")), .text("Hello\u{2028}world")],
              "Finished blocks keep tool detail, drop empty thinking and subagent traffic")
        check(events.contains(.toolResult(toolID: "toolu_2", output: "line\n[image]", isError: true)),
              "Structured tool results flatten to text and keep their error flag")
        check(events.last == .finished(AgentTurnSummary(sessionID: "S1", isError: false, message: "Hello",
                                                        turns: 2, duration: .milliseconds(6111))),
              "The result event closes the turn")
        check(ClaudeCodeStream.events(from: Data("not json".utf8)).isEmpty, "Malformed lines are ignored")

        // Session scoping
        let window = WindowSession(localRoot: root)
        defer { window.close() }
        check(window.agent == nil, "No agent exists outside project mode")
        await window.open(Project(name: "Agent", directoryPath: project.path), at: .local(project))
        let projectAgent = window.agent
        check(projectAgent?.workingDirectory == project, "Opening a project roots its agent in the project folder")
        window.handleTerminalExit(generation: window.terminalGeneration)
        check(window.agent === projectAgent, "A console restart keeps the project's conversation")
        window.closeProject()
        check(window.agent == nil, "Closing the project releases its agent")

        // Process runs against a stand-in CLI
        let fixtureURL = root.appendingPathComponent("fixture.jsonl")
        try (fixture.joined(separator: "\n") + "\n").write(to: fixtureURL, atomically: true, encoding: .utf8)
        let script = root.appendingPathComponent("claude")
        try """
        #!/bin/sh
        pwd -P > "$AGENT_LOG/cwd"
        printf '%s\\n' "$@" > "$AGENT_LOG/args"
        cat > "$AGENT_LOG/prompt"
        case "$AGENT_MODE" in
          fail) echo "Not logged in" >&2; exit 3 ;;
          hang) head -n 1 "$AGENT_FIXTURE"; exec sleep 30 ;;
          *) cat "$AGENT_FIXTURE" ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        var mode = "ok"
        let agent = AgentSession(workingDirectory: project) { request in
            AgentLaunchConfiguration(
                executableURL: script,
                arguments: request.claudeCodeArguments,
                environment: ["AGENT_LOG": log.path, "AGENT_MODE": mode, "AGENT_FIXTURE": fixtureURL.path],
                workingDirectory: project
            )
        }
        func logged(_ name: String) -> String {
            (try? String(contentsOf: log.appendingPathComponent(name), encoding: .utf8)) ?? ""
        }

        agent.send("  -p first prompt\n")
        await finish(agent)
        let reply = agent.messages[1]
        let cwd = URL(fileURLWithPath: logged("cwd").trimmingCharacters(in: .newlines))
        check(cwd.resolvingSymlinksInPath() == project.resolvingSymlinksInPath(), "The CLI runs in the project root")
        check(logged("prompt") == "-p first prompt", "The prompt arrives on stdin, never as a flag")
        check(logged("args").contains("--permission-mode\nacceptEdits") && !logged("args").contains("--resume"),
              "The first turn starts a new session in the chosen mode")
        check(agent.sessionID == "S1", "The session id is kept for the next turn")
        check(reply.blocks.map(\.kind) == [
            .tool(ToolActivity(name: "Bash", detail: "pwd", output: "/project")),
            .text("Hello\u{2028}world")
        ], "Tool results attach to their call; raw U+2028 stays inside its line")
        check(reply.liveText.isEmpty && !reply.isStreaming && !reply.isThinking && reply.error == nil,
              "Streaming state clears once the turn finishes")
        check(reply.footnote?.hasPrefix("2 turns") == true, "The turn summary is shown")

        agent.permissionMode = .plan
        agent.send("second")
        await finish(agent)
        check(logged("args").contains("--resume\nS1") && logged("args").contains("--permission-mode\nplan"),
              "Later turns resume the session with the current permission mode")

        mode = "fail"
        agent.send("third")
        await finish(agent)
        check(agent.messages.last?.error == "Not logged in", "A failed launch shows the CLI's stderr")

        mode = "hang"
        agent.send("fourth")
        while !agent.isRunning || logged("prompt") != "fourth" { try await Task.sleep(for: .milliseconds(10)) }
        let clock = ContinuousClock.now
        agent.stop()
        await finish(agent)
        check(ContinuousClock.now - clock < .seconds(2) && agent.messages.last?.footnote == "Stopped"
              && agent.messages.last?.error == nil, "Stop interrupts a running turn without reporting a failure")

        let missing = AgentSession(workingDirectory: project) { _ in throw AgentError.missingExecutable("claude") }
        missing.send("hello")
        await finish(missing)
        check(missing.messages.last?.error?.contains("not found") == true, "A missing CLI explains itself")

        print("Agent integration checks passed")
    }

    @MainActor static func finish(_ agent: AgentSession) async {
        try? await Task.sleep(for: .milliseconds(10))
        while agent.isRunning { try? await Task.sleep(for: .milliseconds(10)) }
    }

    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fatalError(message) }
        print("PASS: \(message)")
    }
}
