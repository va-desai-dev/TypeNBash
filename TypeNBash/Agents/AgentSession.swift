import Foundation
import Observation

enum MessageRole: String {
    case user
    case assistant
}

struct ToolActivity: Equatable {
    let name: String
    /// The command, path, or query the tool acted on.
    let detail: String
    var output: String?
    var isError = false
}

struct TranscriptBlock: Identifiable, Equatable {
    enum Kind: Equatable {
        case text(String)
        case reasoning(String)
        case tool(ToolActivity)
    }

    /// Tool blocks keep the CLI's tool-use id so their results can find them.
    let id: String
    var kind: Kind

    init(id: String = UUID().uuidString, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

struct ChatMessage: Identifiable, Equatable {
    let id = UUID()
    let role: MessageRole
    var blocks: [TranscriptBlock] = []
    /// The block still streaming; cleared when the CLI reports it finished.
    var liveText = ""
    var liveReasoning = ""
    var isThinking = false
    var isStreaming = false
    var footnote: String?
    var error: String?
}

/// A conversation with a coding agent attributed to one project root. Each
/// prompt runs the CLI once in that root; later prompts resume the CLI's own
/// session, so the agent keeps its context between turns.
@Observable
final class AgentSession {
    let workingDirectory: URL
    var permissionMode: AgentPermissionMode = .acceptEdits
    private(set) var messages: [ChatMessage] = []
    private(set) var isRunning = false
    private(set) var sessionID: String?

    private let launch: (AgentLaunchRequest) async throws -> AgentLaunchConfiguration
    private var process: Process?
    private var stopRequested = false

    init(
        workingDirectory: URL,
        launch: @escaping (AgentLaunchRequest) async throws -> AgentLaunchConfiguration
    ) {
        self.workingDirectory = workingDirectory
        self.launch = launch
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !prompt.isEmpty else { return }
        messages.append(ChatMessage(role: .user, blocks: [TranscriptBlock(kind: .text(prompt))]))
        messages.append(ChatMessage(role: .assistant, isStreaming: true))
        let index = messages.count - 1
        isRunning = true
        stopRequested = false
        Task {
            do {
                try await run(prompt, into: index)
            } catch {
                messages[index].error = error.localizedDescription
            }
            messages[index].isStreaming = false
            messages[index].isThinking = false
            if stopRequested { messages[index].footnote = "Stopped" }
            process = nil
            isRunning = false
        }
    }

    /// Interrupts the turn the way Control-C would, escalating if the CLI ignores it.
    func stop() {
        guard let process, process.isRunning else { return }
        stopRequested = true
        process.interrupt()
        Task {
            try? await Task.sleep(for: .seconds(3))
            if process.isRunning { process.terminate() }
        }
    }

    private func run(_ prompt: String, into index: Int) async throws {
        let configuration = try await launch(
            AgentLaunchRequest(permissionMode: permissionMode, resumeSessionID: sessionID)
        )
        let process = Process()
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.executableURL = configuration.executableURL
        process.arguments = configuration.arguments
        process.environment = configuration.environment
        process.currentDirectoryURL = configuration.workingDirectory
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        // A CLI that dies before reading its prompt must fail the write, not
        // take the app down with SIGPIPE.
        let writer = input.fileHandleForWriting
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        try process.run()
        self.process = process
        let promptData = Data(prompt.utf8)
        Task.detached {
            try? writer.write(contentsOf: promptData)
            try? writer.close()
        }
        // Drained alongside stdout so a chatty stderr cannot fill its pipe and stall the CLI.
        let errorReader = errors.fileHandleForReading
        let diagnostics = Task.detached { (try? errorReader.readToEnd()) ?? Data() }

        // Split on raw newlines: JSON escapes them inside strings, but not
        // U+2028, which a text-aware line reader would also break on.
        var line = Data()
        var summary: AgentTurnSummary?
        for try await byte in output.fileHandleForReading.bytes {
            guard byte == UInt8(ascii: "\n") else {
                line.append(byte)
                continue
            }
            for event in ClaudeCodeStream.events(from: line) {
                if case .finished(let result) = event { summary = result }
                apply(event, to: index)
            }
            line.removeAll(keepingCapacity: true)
        }
        while process.isRunning {
            try await Task.sleep(for: .milliseconds(30))
        }
        let stderr = String(decoding: await diagnostics.value, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if summary == nil, !stopRequested, process.terminationStatus != 0 {
            throw AgentError.exited(status: process.terminationStatus, message: stderr)
        }
    }

    private func apply(_ event: AgentEvent, to index: Int) {
        switch event {
        case .started(let id):
            sessionID = id
        case .textDelta(let text):
            messages[index].isThinking = false
            messages[index].liveText += text
        case .reasoningDelta(let text):
            messages[index].isThinking = true
            messages[index].liveReasoning += text
        case .block(let block):
            messages[index].liveText = ""
            messages[index].liveReasoning = ""
            messages[index].isThinking = false
            messages[index].blocks.append(block)
        case .toolResult(let toolID, let output, let isError):
            guard let position = messages[index].blocks.firstIndex(where: { $0.id == toolID }),
                  case .tool(var tool) = messages[index].blocks[position].kind else { return }
            tool.output = output
            tool.isError = isError
            messages[index].blocks[position].kind = .tool(tool)
        case .finished(let summary):
            sessionID = summary.sessionID ?? sessionID
            if summary.isError { messages[index].error = summary.message }
            let seconds = summary.duration.formatted(.units(allowed: [.minutes, .seconds], width: .narrow))
            messages[index].footnote = "\(summary.turns) \(summary.turns == 1 ? "turn" : "turns") · \(seconds)"
        }
    }
}
