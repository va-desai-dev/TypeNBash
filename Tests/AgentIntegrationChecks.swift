import Foundation
#if !HARNESS_CORE
import AppKit
import SwiftUI
@testable import TypeNBash
#endif

actor ScriptedAgentProvider: AgentProvider {
    nonisolated let kind: AgentProviderKind
    let call: AgentToolCall
    var requests: [[AgentJSON]] = []
    init(call: AgentToolCall, kind: AgentProviderKind = .openAI) { self.call = call; self.kind = kind }
    func respond(history: [AgentJSON], tools: [AgentToolDefinition], onText: @escaping @Sendable (String) async -> Void) async throws -> AgentResponse {
        requests.append(history)
        if requests.count == 1 {
            let item = kind == .chatCompletions ? AgentJSON.object(["role": .string("assistant"), "content": .null,
                "tool_calls": .array([.object(["id": .string(call.id), "type": .string("function"),
                    "function": .object(["name": .string(call.name), "arguments": .string(call.arguments.encoded)])])])])
                : AgentJSON.object(["type": .string("function_call"), "call_id": .string(call.id),
                "name": .string(call.name), "arguments": .string(call.arguments.encoded)])
            return AgentResponse(items: [item], text: "", calls: [call])
        }
        await onText("Done")
        return AgentResponse(items: [.object(["role": .string("assistant"), "content": .string("Done")])], text: "Done", calls: [])
    }
}

actor AgentCheckLog {
    var calls = 0
    var snapshot = AgentConversation()
    func executed() { calls += 1 }
    func receive(_ event: AgentRunEvent) {
        if case .checkpoint(let state) = event { snapshot = state }
    }
}

final class AgentProtocolFixture: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = request.value(forHTTPHeaderField: "Authorization") == "Bearer invalid" ? 401 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let events = request.url?.path.hasSuffix("/chat/completions") == true ? [
            #"{"choices":[{"index":0,"delta":{"content":"Hello"},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":1}}"#,
            "[DONE]"
        ] : [
            #"{"type":"response.output_text.delta","delta":"Hello"}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Hello"}]}],"usage":{"input_tokens":4,"output_tokens":1}}}"#
        ]
        let planEvents = [
            #"{"type":"response.output_text.delta","delta":"Hello"}"#,
            #"{"type":"response.output_item.done","output_index":0,"item":{"type":"message","role":"assistant","status":"completed","content":[{"type":"output_text","text":"Hello"}]}}"#,
            #"{"type":"response.completed","response":{"status":"completed","output":[],"usage":{"input_tokens":570,"output_tokens":22}}}"#
        ]
        let stream = (request.value(forHTTPHeaderField: "Authorization") == "Bearer chatgpt-fixture" ? planEvents : events)
            .map { "data: \($0)\r\n\r\n" }.joined()
        for chunk in stride(from: 0, to: stream.utf8.count, by: 7) {
            client?.urlProtocol(self, didLoad: Data(Array(stream.utf8).dropFirst(chunk).prefix(7)))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct AgentIntegrationChecks {
    static func check(_ value: Bool, _ message: String) {
        precondition(value, message)
        print("PASS: \(message)")
    }
    static func rejected(_ message: String, _ action: () throws -> Void) {
        do { try action(); fatalError(message) } catch { print("PASS: \(message)") }
    }
    static func call(_ name: String, _ values: [String: AgentJSON]) -> AgentToolCall {
        .init(id: UUID().uuidString, name: name, arguments: .object(values))
    }
    #if HARNESS_CORE
    @MainActor static func main() async throws { try await runChecks() }
    #else
    @MainActor static func main() {
        setbuf(stdout, nil)
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do { try await runChecks(); exit(0) }
            catch { print("FAIL: \(error)"); exit(1) }
        }
        NSApp.run()
    }
    #endif

    @MainActor static func runChecks() async throws {
        let root = URL(fileURLWithPath: "/tmp/byok-checks-" + UUID().uuidString)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let access = try AgentWorkspaceAccess(root: root)
        let tools = try AgentWorkspaceTools(root: root)
        let file = root.appendingPathComponent("hello.txt")
        try Data("hello\nworld\n".utf8).write(to: file)
        let read = try await tools.read(call("read_file", ["path": .string("hello.txt"), "offset": .number(0)]))
        let json = try JSONDecoder().decode(AgentJSON.self, from: Data(read.utf8))
        let change = try await tools.prepare(call("apply_edits", ["path": .string("hello.txt"), "revision": json["revision"],
            "old_text": .string("hello"), "new_text": .string("goodbye")]))
        try access.commit(change)
        check(try String(contentsOf: file, encoding: .utf8) == "goodbye\nworld\n", "Native exact edit commits")
        rejected("Stale revisions do not overwrite newer edits") { try access.commit(change) }
        rejected("Traversal is rejected") { _ = try access.read("../outside") }
        rejected("Absolute paths are rejected") { _ = try access.read(file.path) }
        rejected("Credentials are excluded") { _ = try access.read(".env") }
        try fm.createSymbolicLink(atPath: root.appendingPathComponent("link").path, withDestinationPath: "/tmp")
        rejected("Symlink parent traversal is rejected") { _ = try access.read("link/outside") }
        rejected("Creation through symlinks is rejected") {
            try access.commit(.init(path: "link/new", before: nil, after: "bad", revision: ""))
        }
        try fm.linkItem(at: file, to: root.appendingPathComponent("hardlink"))
        rejected("Hard-linked files are rejected") { _ = try access.read("hardlink") }
        try fm.removeItem(at: root.appendingPathComponent("hardlink"))
        rejected("Create never overwrites an existing file") {
            try access.commit(.init(path: "hello.txt", before: nil, after: "bad", revision: ""))
        }
        try Data([0, 255, 1]).write(to: root.appendingPathComponent("binary"))
        rejected("Binary files are rejected") { _ = try access.read("binary") }
        let search = try await tools.read(call("search_files", ["path": .string("."), "query": .string("goodbye"), "offset": .number(0)]))
        check(search.contains("hello.txt") && !search.contains("hardlink"), "Search uses native workspace reads")
        let created = try await tools.prepare(call("create_file", ["path": .string("new.txt"), "content": .string("new")]))
        try access.commit(created)
        check(try access.read("new.txt") == Data("new".utf8), "Exclusive native file creation works")
        try access.commit(.init(path: "folder", before: nil, after: nil, revision: "", isDirectory: true))
        check(try access.list(".").contains(where: { $0.name == "folder" && $0.directory }), "Native directory creation works")
        let listing = try await tools.read(call("list_files", ["path": .string("."), "offset": .number(200)]))
        check(listing.contains("\"entries\":[]"), "Listing pagination terminates")
        try streamChecks()
        try planStreamChecks()
        try connectionChecks()
        try chatStreamChecks()
        try await providerChecks()
        try await runnerChecks()
        #if !APP_STORE
        try await shellChecks(root)
        #else
        check(!AgentBuildCapabilities.localCommands, "App Store binary has no local command capability")
        #endif
        #if !HARNESS_CORE
        try await sessionChecks(root)
        #endif
        print("All BYOK integration checks passed; no live provider calls made.")
    }

    static func streamChecks() throws {
        var decoder = AgentSSEDecoder()
        let payload = "{\"type\":\"response.output_text.delta\",\"delta\":\"café\u{2028}tail\"}"
        var frames: [Data] = []
        for byte in Data(": ping\r\nevent: test\r\ndata: \(payload)\r\n\r\n".utf8) {
            if let data = try decoder.feed(byte) { frames.append(data) }
        }
        check(frames == [Data(payload.utf8)], "SSE handles CRLF, byte fragmentation, Unicode and comments")
        var openAI = AgentProviderStream(kind: .openAI)
        _ = try openAI.consume(frames[0])
        rejected("EOF before completion rejects partial responses") { _ = try openAI.finish() }
        let output = #"{"type":"response.completed","response":{"status":"completed","output":[{"type":"reasoning","id":"r1","encrypted_content":"opaque"},{"type":"function_call","call_id":"c1","name":"read_file","arguments":"{\"path\":\"hello.txt\",\"offset\":0}"}],"usage":{"input_tokens":20,"output_tokens":10}}}"#
        _ = try openAI.consume(Data(output.utf8))
        let complete = try openAI.finish()
        check(complete.calls.count == 1 && complete.items[0]["encrypted_content"].string == "opaque", "OpenAI preserves opaque reasoning and complete tool calls")
        check(complete.inputTokens == 20 && complete.outputTokens == 10, "OpenAI usage is captured")
        var anthropic = AgentProviderStream(kind: .anthropic)
        let events = [
            #"{"type":"message_start","message":{"usage":{"input_tokens":10}}}"#,
            #"{"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":"","signature":""}}"#,
            #"{"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"signed"}}"#,
            #"{"type":"content_block_stop","index":0}"#,
            #"{"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"t1","name":"read_file","input":{}}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":"}}"#,
            #"{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"\"hello.txt\",\"offset\":0}"}}"#,
            #"{"type":"content_block_stop","index":1}"#,
            #"{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":30}}"#,
            #"{"type":"message_stop"}"#
        ]
        for event in events { _ = try anthropic.consume(Data(event.utf8)) }
        let result = try anthropic.finish()
        check(result.calls.first?.arguments["path"].string == "hello.txt", "Anthropic assembles fragmented tool arguments")
        check(result.items[0]["content"].array[0]["signature"].string == "signed", "Anthropic signed continuation blocks survive")
        var failed = AgentProviderStream(kind: .openAI)
        rejected("Incomplete responses cannot execute tools") { _ = try failed.consume(Data(#"{"type":"response.incomplete"}"#.utf8)) }
        let messages = AgentProviderKind.anthropic.resultMessages([.init(id: "t1", output: "declined", isError: true)])
        check(messages[0]["content"].array[0]["is_error"] == .bool(true), "Tool errors use Anthropic's result envelope")
    }

    static func planStreamChecks() throws {
        let reasoning = AgentJSON.object(["type": .string("reasoning"), "id": .string("r1"), "encrypted_content": .string("opaque")])
        let tool = AgentJSON.object(["type": .string("function_call"), "call_id": .string("c1"),
            "namespace": .string("workspace"), "name": .string("read_file"), "status": .string("completed"),
            "arguments": .string(#"{"path":"hello.txt","offset":0}"#)])
        let message = AgentJSON.object(["type": .string("message"), "role": .string("assistant"),
            "content": .array([.object(["type": .string("output_text"), "text": .string("Hello")])])])
        let completed = AgentJSON.object(["type": .string("response.completed"), "response": .object([
            "status": .string("completed"), "output": .array([]),
            "usage": .object(["input_tokens": .number(570), "output_tokens": .number(22)])])])
        func done(_ item: AgentJSON, _ index: Int) -> Data {
            Data(AgentJSON.object(["type": .string("response.output_item.done"),
                "output_index": .number(Double(index)), "item": item]).encoded.utf8)
        }
        var stream = AgentProviderStream(kind: .openAI, toolNamespace: "workspace")
        _ = try stream.consume(Data(#"{"type":"response.output_text.delta","delta":"Hello"}"#.utf8))
        // Deliberately interleave item completion; continuation must retain output order.
        _ = try stream.consume(done(tool, 2))
        _ = try stream.consume(done(reasoning, 0))
        _ = try stream.consume(done(message, 1))
        rejected("Completed tools cannot execute before response.completed") { _ = try stream.finish() }
        _ = try stream.consume(Data(completed.encoded.utf8))
        let result = try stream.finish()
        check(result.items == [reasoning, message, tool] && result.text == "Hello",
              "Empty terminal output retains completed text, ordered items and opaque reasoning")
        check(result.calls.count == 1 && result.calls[0].name == "read_file" && result.outputTokens == 22,
              "Namespaced completed tool calls dispatch by local name with usage intact")
        var duplicated = stream
        _ = try duplicated.consume(Data(completed.setting("response", completed["response"].setting("output", .array(result.items))).encoded.utf8))
        check(try duplicated.finish().items == result.items, "Terminal output does not duplicate completed items")
        var empty = AgentProviderStream(kind: .openAI)
        _ = try empty.consume(Data(completed.encoded.utf8))
        rejected("Empty successful responses surface an error instead of a blank assistant") { _ = try empty.finish() }
        var partial = AgentProviderStream(kind: .openAI, toolNamespace: "workspace")
        _ = try partial.consume(done(tool.setting("status", .string("incomplete")), 0))
        _ = try partial.consume(Data(completed.encoded.utf8))
        rejected("Incomplete tool items cannot execute even after response completion") { _ = try partial.finish() }
        var wrongNamespace = AgentProviderStream(kind: .openAI, toolNamespace: "workspace")
        _ = try wrongNamespace.consume(done(tool.setting("namespace", .string("other")), 0))
        _ = try wrongNamespace.consume(Data(completed.encoded.utf8))
        rejected("Unexpected tool namespaces cannot dispatch workspace tools") { _ = try wrongNamespace.finish() }
        var failed = AgentProviderStream(kind: .openAI, toolNamespace: "workspace")
        _ = try failed.consume(done(tool, 0))
        rejected("A failed response cannot release completed tools") {
            _ = try failed.consume(Data(#"{"type":"response.failed","response":{"error":{"code":"server_error"}}}"#.utf8))
        }
        rejected("Failed response remains incomplete") { _ = try failed.finish() }
    }

    static func providerChecks() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [AgentProtocolFixture.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var openAI = AgentConnectionPreset.openAI.connection
        openAI.model = "test-model"
        let provider = AgentHTTPProvider(connection: openAI, key: "fixture", session: session)
        let request = try provider.request(history: [.object(["role": .string("user"), "content": .string("test")])], tools: AgentWorkspaceTools.definitions)
        let body = try JSONDecoder().decode(AgentJSON.self, from: request.httpBody!)
        check(body["store"] == .bool(false) && body["include"].array.contains(.string("reasoning.encrypted_content")), "OpenAI requests stateless continuation")
        check(!String(decoding: request.httpBody!, as: UTF8.self).contains("fixture"), "API key stays out of request content")
        let response = try await provider.respond(history: [], tools: []) { _ in }
        check(response.text == "Hello" && response.outputTokens == 1, "HTTP transport consumes fragmented fixture stream")
        let plan = AgentHTTPProvider(connection: AgentConnectionPreset.chatGPT.connection, key: "chatgpt-fixture", session: session)
        let planRequest = try plan.request(history: [], tools: AgentWorkspaceTools.definitions)
        let planBody = try JSONDecoder().decode(AgentJSON.self, from: planRequest.httpBody!)
        let namespace = planBody["tools"].array[0]
        check(planBody["tools"].array.count == 1 && namespace["type"].string == "namespace"
              && namespace["name"].string == "workspace" && namespace["tools"].array.count == AgentWorkspaceTools.definitions.count
              && namespace["tools"].array.allSatisfy { $0["type"].string == "function" && $0["strict"] == .bool(true) },
              "ChatGPT plan wraps strict workspace functions in a namespace")
        check(planBody["max_output_tokens"] == .null && planBody["store"] == .bool(false) && planBody["stream"] == .bool(true),
              "ChatGPT plan request retains required inference parameters")
        let planResponse = try await plan.respond(history: [], tools: AgentWorkspaceTools.definitions) { _ in }
        check(planResponse.text == "Hello" && planResponse.items.count == 1 && planResponse.outputTokens == 22,
              "ChatGPT HTTP stream retains the answer with empty terminal output")
        check(body["tools"].array[0]["type"].string == "function", "API-key Responses keeps its existing tool format")
        do {
            _ = try await AgentHTTPProvider(connection: openAI, key: "invalid", session: session).respond(history: [], tools: []) { _ in }
            fatalError("Unauthorized response accepted")
        } catch { check(error.localizedDescription.contains("rejected"), "Authentication errors surface without exposing keys") }
        var anthropicConnection = AgentConnectionPreset.anthropic.connection
        anthropicConnection.model = "test"
        let anthropic = AgentHTTPProvider(connection: anthropicConnection, key: "fixture")
        let anthropicRequest = try anthropic.request(history: [], tools: AgentWorkspaceTools.definitions)
        let anthropicBody = try JSONDecoder().decode(AgentJSON.self, from: anthropicRequest.httpBody!)
        check(anthropicRequest.value(forHTTPHeaderField: "x-api-key") == "fixture" && anthropicBody["tools"].array[0]["input_schema"]["type"].string == "object", "Anthropic request maps native schemas and headers")
        var engrai = AgentConnectionPreset.engrai.connection
        engrai.model = "fixture-model"
        let chat = AgentHTTPProvider(connection: engrai, key: "engrai-fixture", session: session)
        let chatRequest = try chat.request(history: [.object(["role": .string("user"), "content": .string("test")])], tools: AgentWorkspaceTools.definitions)
        let chatBody = try JSONDecoder().decode(AgentJSON.self, from: chatRequest.httpBody!)
        check(chatRequest.url?.absoluteString == "https://llm.engrai.app/v1/chat/completions"
            && chatRequest.value(forHTTPHeaderField: "Authorization") == "Bearer engrai-fixture", "ENGRAISERVER uses configured URL and bearer header")
        check(chatBody["messages"].array.count == 2 && chatBody["tools"].array[0]["function"]["parameters"]["type"].string == "object"
            && chatBody["input"] == .null, "Chat Completions encodes system message and nested function schemas")
        check(try await chat.respond(history: [], tools: []) { _ in }.text == "Hello", "Chat transport handles fragmented SSE and final usage")
        var ollama = AgentConnectionPreset.ollama.connection
        ollama.model = "fixture-model"
        let local = AgentHTTPProvider(connection: ollama, key: "must-not-send")
        let localRequest = try local.request(history: [], tools: AgentWorkspaceTools.definitions)
        let localBody = try JSONDecoder().decode(AgentJSON.self, from: localRequest.httpBody!)
        check(localRequest.value(forHTTPHeaderField: "Authorization") == nil && localRequest.value(forHTTPHeaderField: "x-api-key") == nil,
            "No-auth connections send no credential, even if one is supplied")
        check(localBody["store"] == .null && localBody["include"] == .null && localBody["tools"].array[0]["strict"] == .null,
            "Ollama Responses omits OpenAI-only extensions")
        var cloud = AgentConnectionPreset.ollamaCloud.connection
        cloud.model = "fixture-model"
        let cloudRequest = try AgentHTTPProvider(connection: cloud, key: "ollama-fixture").request(history: [], tools: [])
        check(cloudRequest.url?.absoluteString == "https://ollama.com/v1/responses"
            && cloudRequest.value(forHTTPHeaderField: "Authorization") == "Bearer ollama-fixture", "Direct Ollama Cloud uses its own endpoint and bearer credential")
    }

    static func connectionChecks() throws {
        var connection = AgentConnectionPreset.engrai.connection
        for base in ["https://llm.engrai.app", "https://llm.engrai.app/v1/", "https://llm.engrai.app/v1/chat/completions"] {
            connection.baseURL = base
            check(try connection.endpoint().absoluteString == "https://llm.engrai.app/v1/chat/completions", "Origin/base/full endpoint normalizes without duplicated path")
        }
        connection.baseURL = "https://example.com/gateway/v1"
        check(try connection.endpoint().path == "/gateway/v1/chat/completions", "Gateway path prefixes survive")
        let firstAccount = try connection.credentialAccount()
        connection.baseURL = "https://other.example/gateway/v1"
        check(try connection.credentialAccount() != firstAccount, "Changing endpoints cannot reuse the previous endpoint's credential")
        for base in ["https://user:secret@example.com/v1", "https://example.com/v1?key=secret", "https://example.com/v1#fragment", "file:///tmp", "http://public.example/v1"] {
            connection.baseURL = base
            rejected("Unsafe or ambiguous endpoint is rejected") { _ = try connection.endpoint() }
        }
        for base in ["http://localhost:11434/v1", "http://192.168.1.2:8080/v1", "http://[::1]:8080/v1"] {
            connection.baseURL = base
            check(try connection.endpoint().scheme == "http", "Local HTTP model endpoints are accepted")
        }
    }

    static func chatStreamChecks() throws {
        let events = [
            #"{"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"thinking","tool_calls":[{"index":1,"id":"b","type":"function","function":{"name":"read_","arguments":"{\"path\":"}},{"index":0,"id":"a","type":"function","function":{"name":"list_files","arguments":"{\"path\":\".\",\"offset\":0}"}}]},"finish_reason":null}]}"#,
            #"{"choices":[{"index":0,"delta":{"tool_calls":[{"index":1,"function":{"name":"file","arguments":"\"hello.txt\",\"offset\":0}"}}]},"finish_reason":"tool_calls"}]}"#,
            #"{"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":10}}"#,
            "[DONE]"
        ]
        var stream = AgentProviderStream(kind: .chatCompletions)
        _ = try stream.consume(Data(events[0].utf8))
        rejected("Partial chat calls never become executable") { _ = try stream.finish() }
        for event in events.dropFirst() { _ = try stream.consume(Data(event.utf8)) }
        let result = try stream.finish()
        check(result.calls.map(\.id) == ["a", "b"] && result.calls[1].name == "read_file"
            && result.calls[1].arguments["path"].string == "hello.txt", "Interleaved chat tool names and arguments assemble by index")
        check(result.items[0]["tool_calls"].array.count == 2 && result.items[0]["reasoning_content"].string == "thinking"
            && result.inputTokens == 20 && result.outputTokens == 10, "Chat continuation retains tools, reasoning and usage")
        let messages = AgentProviderKind.chatCompletions.resultMessages([.init(id: "a", output: "declined", isError: true)])
        check(messages[0]["role"].string == "tool" && messages[0]["tool_call_id"].string == "a"
            && messages[0]["content"].string == "ERROR: declined", "Chat tool results use matching role and call ID")
        var truncated = AgentProviderStream(kind: .chatCompletions)
        rejected("Token truncation rejects chat calls") {
            _ = try truncated.consume(Data(#"{"choices":[{"index":0,"delta":{},"finish_reason":"length"}]}"#.utf8))
        }
        var premature = AgentProviderStream(kind: .chatCompletions)
        rejected("DONE without finish reason is rejected") { _ = try premature.consume(Data("[DONE]".utf8)) }
        var duplicate = AgentProviderStream(kind: .chatCompletions)
        for event in events { _ = try duplicate.consume(Data(event.replacingOccurrences(of: "\"id\":\"b\"", with: "\"id\":\"a\"").utf8)) }
        rejected("Duplicate chat call IDs are rejected") { _ = try duplicate.finish() }
    }

    static func runnerChecks() async throws {
        let read = call("read_file", ["path": .string("hello.txt"), "offset": .number(0)])
        let provider = ScriptedAgentProvider(call: read)
        let log = AgentCheckLog()
        let runner = AgentRunner(provider: provider, tools: AgentWorkspaceTools.definitions)
        try await runner.run("inspect", execute: { call in
            await log.executed(); return .init(id: call.id, output: "hello")
        }, emit: { await log.receive($0) })
        check(await log.calls == 1, "Runner executes a complete tool exactly once")
        let requests = await provider.requests
        check(requests.count == 2 && requests[1].contains(where: { $0["type"].string == "function_call_output" }), "Runner sends tool results before continuation")
        let chat = ScriptedAgentProvider(call: read, kind: .chatCompletions)
        let chatLog = AgentCheckLog()
        try await AgentRunner(provider: chat, tools: AgentWorkspaceTools.definitions).run("inspect", execute: { call in
            await chatLog.executed(); return .init(id: call.id, output: "hello")
        }, emit: { await chatLog.receive($0) })
        let chatRequests = await chat.requests
        check(await chatLog.calls == 1 && chatRequests[1].contains(where: { $0["role"].string == "tool" && $0["tool_call_id"].string == read.id })
            && chatRequests[1].contains(where: { !$0["tool_calls"].array.isEmpty }), "Chat runner round trip retains assistant calls and matching results")
        let unknown = ScriptedAgentProvider(call: call("run_command", ["command": .string("touch bad"), "timeout_seconds": .number(1)]))
        let blocked = AgentCheckLog()
        try await AgentRunner(provider: unknown, tools: AgentWorkspaceTools.definitions).run("inspect", execute: { call in
            await blocked.executed(); return .init(id: call.id, output: "bad")
        }, emit: { await blocked.receive($0) })
        check(await blocked.calls == 0, "Unadvertised shell calls are denied at dispatch")
        var pending = AgentConversation(history: [], pending: [read], results: [])
        pending.settlePending(provider: .openAI)
        check(pending.pending.isEmpty && pending.history[0]["output"].string?.contains("Interrupted") == true, "Recovery records uncertain execution without replay")
        let cancelledProvider = ScriptedAgentProvider(call: read)
        let cancelled = AgentCheckLog()
        let run = Task {
            try await AgentRunner(provider: cancelledProvider, tools: AgentWorkspaceTools.definitions).run("inspect", execute: { _ in
                try await Task.sleep(for: .seconds(30)); throw CancellationError()
            }, emit: { await cancelled.receive($0) })
        }
        while await cancelled.snapshot.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        run.cancel()
        do { try await run.value; fatalError("Cancellation ignored") } catch is CancellationError {}
        check(await cancelled.snapshot.pending.isEmpty, "Cancellation settles outstanding calls")
    }

    #if !APP_STORE
    static func shellChecks(_ root: URL) async throws {
        check(AgentBuildCapabilities.localCommands, "DMG has explicit local command capability")
        let output = try await AgentLocalCommand().run(command: "pwd; printf 'out'; printf 'err' >&2; exit 7", root: root, timeout: 5)
        let result = try JSONDecoder().decode(AgentJSON.self, from: Data(output.utf8))
        check(result["stdout"].string?.contains(root.path) == true && result["stderr"].string == "err" && result["exit_code"].integer == 7, "Commands report cwd, both output streams, and exit status")
        let pidFile = root.appendingPathComponent("child.pid")
        let task = Task { try await AgentLocalCommand().run(command: "sleep 30 & echo $! > child.pid; wait", root: root, timeout: 60) }
        for _ in 0..<100 {
            if fmExists(pidFile) { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let pid = Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines))!
        task.cancel()
        do { _ = try await task.value; fatalError("Command cancellation ignored") } catch is CancellationError {}
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(kill(pid, 0) != 0, "Stop terminates ordinary shell descendants")
        do { _ = try await AgentLocalCommand().run(command: "sleep 30", root: root, timeout: 1); fatalError("Timeout ignored") }
        catch { check(error.localizedDescription.contains("timed out"), "Commands enforce timeout") }
    }
    static func fmExists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }
    #endif

    #if !HARNESS_CORE
    @MainActor static func sessionChecks(_ root: URL) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AgentProtocolFixture.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let plan = AgentHTTPProvider(connection: AgentConnectionPreset.chatGPT.connection, key: "chatgpt-fixture", session: transport)
        let chat = AgentSession(workingDirectory: root, workspaceID: UUID().uuidString, persists: false, provider: plan)
        chat.send("Say Hello")
        for _ in 0..<500 {
            if !chat.isRunning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(!chat.isRunning && chat.messages.last?.error == nil
              && chat.messages.last?.blocks.contains(where: { $0.kind == .text("Hello") }) == true,
              "DEBUG session retains ChatGPT answer after streaming completes")
        let planStore = try AgentConversationStore(inMemory: true)
        try planStore.save(chat.snapshot, workspace: "plan-test")
        check(try planStore.latest(workspace: "plan-test")?.messages == chat.messages
              && chat.snapshot.conversation.history.count == 2,
              "ChatGPT completed answer persists in both transcript and continuation history")
        let create = call("create_file", ["path": .string("approved.txt"), "content": .string("approved")])
        let session = AgentSession(workingDirectory: root, workspaceID: UUID().uuidString, persists: false, provider: ScriptedAgentProvider(call: create))
        session.send("create")
        for _ in 0..<200 {
            if session.approval != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check(session.approval != nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path), "Ask mode pauses before writing")
        if ProcessInfo.processInfo.environment["BYOK_RENDER_CHECKS"] == "1" { try await render(session) }
        session.resolveApproval(false)
        while session.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        check(!FileManager.default.fileExists(atPath: root.appendingPathComponent("approved.txt").path), "Declined edits never touch disk")
        let approved = AgentSession(workingDirectory: root, workspaceID: UUID().uuidString, persists: false, provider: ScriptedAgentProvider(call: create))
        approved.send("create")
        while approved.approval == nil && approved.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        approved.resolveApproval(true)
        while approved.isRunning { try await Task.sleep(for: .milliseconds(10)) }
        check(try String(contentsOf: root.appendingPathComponent("approved.txt"), encoding: .utf8) == "approved", "Approved edit is committed and recorded")
        check(approved.changes.count == 1, "Completed edits are reviewable")
        let store = try AgentConversationStore(inMemory: true)
        try store.save(approved.snapshot, workspace: "test")
        check(try store.latest(workspace: "test")?.messages == approved.messages, "SwiftData restores transcript and continuation state")
        let model = FileBrowserModel(fileSystem: LocalWorkspaceFileSystem())
        AgentEditorCoordinator.shared.register(model)
        let file = root.appendingPathComponent("approved.txt")
        model.select(.init(url: file, isDirectory: false, byteCount: nil))
        for _ in 0..<100 {
            if case .text = model.preview { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        model.updatePreviewText("unsaved")
        let change = AgentFileChange(path: "approved.txt", before: "approved", after: "overwrite", revision: AgentWorkspaceAccess.revision(Data("approved".utf8)))
        do {
            try await AgentEditorCoordinator.shared.commit(change, access: AgentWorkspaceAccess(root: root))
            fatalError("Agent edits cannot overwrite an unsaved editor buffer")
        } catch { print("PASS: Agent edits cannot overwrite an unsaved editor buffer") }
        let credentials = AgentCredentialStore(service: "com.TypeNBash.tests.byok." + UUID().uuidString)
        defer { try? credentials.delete("anthropic"); try? credentials.delete("openAI") }
        try credentials.save("fixture-one", for: "anthropic")
        try credentials.save("fixture-two", for: "openAI")
        check(try credentials.read("anthropic") == "fixture-one" && credentials.read("openAI") == "fixture-two", "Provider credentials are separate Keychain entries")
        try credentials.delete("anthropic")
        check(try credentials.read("anthropic") == nil, "Keychain deletion works")
        let suite = "com.TypeNBash.tests.connections." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AgentSettings(defaults: defaults, credentials: credentials)
        check(settings.preset == .engrai, "Fresh settings default to the custom server, without a paid API requirement")
        settings.connection.model = "engrai-model"
        settings.apiKey = "endpoint-fixture"
        settings.saveKey()
        let original = settings.connection
        defer { try? credentials.delete(original.credentialAccount()) }
        check(settings.hasKey, "Custom bearer credential saves to Keychain")
        settings.connection.baseURL = "https://different.example/v1"
        check(!settings.hasKey && settings.apiKey.isEmpty, "Editing the endpoint clears the visible credential state")
        rejected("New endpoint cannot use another endpoint's saved key") { _ = try settings.makeProvider(connection: settings.connection) }
        let frozen = try settings.makeProvider(connection: original)
        check(frozen.connection.baseURL == original.baseURL && frozen.key == "endpoint-fixture", "Frozen conversations resolve credentials against their original endpoint")
        settings.connection = original
        settings.preset = .ollama
        settings.connection.model = "local-model"
        check(try settings.makeProvider(connection: settings.connection).key.isEmpty, "Local connection needs no Keychain credential")
        let restored = AgentSettings(defaults: defaults, credentials: credentials)
        check(restored.preset == .ollama && restored.connection.model == "local-model", "Connection selection persists")
        restored.preset = .engrai
        check(restored.connection == original, "Each server retains its independent settings")
        let saved = defaults.data(forKey: "agent.connections")!
        check(!String(decoding: saved, as: UTF8.self).contains("endpoint-fixture"), "Credentials never enter settings persistence")
        restored.connection.baseURL = "https://user:secret@example.com/v1"
        check(defaults.data(forKey: "agent.connections") == saved, "Embedded URL credentials are not persisted")
        var frozenSnapshot = approved.snapshot
        frozenSnapshot.provider = original.kind; frozenSnapshot.model = original.model; frozenSnapshot.connection = original
        try store.save(frozenSnapshot, workspace: "test")
        check(try store.latest(workspace: "test")?.connection == original, "Conversation storage retains its exact endpoint and authentication mode")
    }

    @MainActor static func render(_ session: AgentSession) async throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        for width in [300.0, 400.0] {
            let host = NSHostingView(rootView: AgenticChatView(session: session).environment(\.colorScheme, .dark))
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: 700),
                styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            check(host.frame.width == width, "Agent inspector fits \(Int(width))-point width")
            let renderer = ImageRenderer(content: AgenticChatView(session: session)
                .environment(\.colorScheme, .dark).frame(width: width, height: 700).background(Color.black))
            renderer.scale = 2
            if let data = renderer.nsImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data) {
                try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "/tmp/byok-inspector-\(Int(width)).png"))
            }
            window.close()
        }
    }
    #endif
}
