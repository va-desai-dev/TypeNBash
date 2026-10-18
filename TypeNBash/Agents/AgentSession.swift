import Foundation
import Observation

nonisolated enum MessageRole: String, Codable, Sendable {
    case user
    case assistant
}

nonisolated struct ToolActivity: Codable, Equatable, Sendable {
    let name: String
    /// The command, path, or query the tool acted on.
    let detail: String
    var output: String?
    var isError = false
}

nonisolated struct TranscriptBlock: Identifiable, Codable, Equatable, Sendable {
    enum Kind: Codable, Equatable, Sendable {
        case text(String)
        case reasoning(String)
        case tool(ToolActivity)
    }

    /// Tool blocks keep the provider's tool-call ID so their results can find them.
    let id: String
    var kind: Kind

    init(id: String = UUID().uuidString, kind: Kind) {
        self.id = id
        self.kind = kind
    }
}

nonisolated struct ChatMessage: Identifiable, Codable, Equatable, Sendable {
    var id = UUID()
    let role: MessageRole
    var blocks: [TranscriptBlock] = []
    /// The block still streaming; cleared when the provider completes the response.
    var liveText = ""
    var liveReasoning = ""
    var isThinking = false
    var isStreaming = false
    var footnote: String?
    var error: String?
}

nonisolated struct AgentApproval: Identifiable, Sendable {
    let id = UUID()
    let title: String
    let detail: String
}

@MainActor @Observable
final class AgentSession {
    let workingDirectory: URL
    var permissionMode: AgentPermissionMode = .ask
    var allowsCommands = false
    private(set) var snapshot: AgentSessionSnapshot
    private(set) var isRunning = false
    private(set) var approval: AgentApproval?
    private(set) var persistenceError: String?
    private(set) var configurationError: String?
    var messages: [ChatMessage] { snapshot.messages }
    var providerTitle: String {
        if snapshot.model.isEmpty {
            (snapshot.connection?.name ?? snapshot.provider.title)
        } else {
            snapshot.model
        }
    }
    var changes: [AgentFileChange] { snapshot.changes }

    private let workspaceID: String
    private let isLocal: Bool
    private let persists: Bool
    private let folderGrant: WorkspaceFolderGrant?
    private let providerOverride: (any AgentProvider)?
    private var task: Task<Void, Never>?
    private var decision: CheckedContinuation<Bool, Never>?
    private var inputTokens = 0
    private var outputTokens = 0

    init(workingDirectory: URL, workspaceID: String, isLocal: Bool = true, folderGrant: WorkspaceFolderGrant? = nil,
         persists: Bool = true, provider: (any AgentProvider)? = nil) {
        self.workingDirectory = workingDirectory; self.workspaceID = workspaceID
        self.isLocal = isLocal; self.persists = persists; self.folderGrant = folderGrant
        providerOverride = provider
        let connection = AgentSettings.shared.connection
        snapshot = AgentSessionSnapshot(provider: connection.kind, model: connection.model, connection: connection)
        if persists {
            do {
                if var restored = try AgentConversationStore.shared.get().latest(workspace: workspaceID) {
                    restored.conversation.settlePending(provider: restored.provider)
                    for index in restored.messages.indices where restored.messages[index].isStreaming {
                        restored.messages[index].isStreaming = false
                        restored.messages[index].isThinking = false
                        restored.messages[index].footnote = "Interrupted; completed edits were retained."
                        for block in restored.messages[index].blocks.indices {
                            if case .tool(var tool) = restored.messages[index].blocks[block].kind, tool.output == nil {
                                tool.output = "Interrupted; inspect current state before retrying."
                                tool.isError = true
                                restored.messages[index].blocks[block].kind = .tool(tool)
                            }
                        }
                    }
                    snapshot = restored
                }
            } catch { persistenceError = "Conversation storage: " + error.localizedDescription }
        }
    }

    func newConversation() {
        guard !isRunning else { return }
        let connection = AgentSettings.shared.connection
        do { _ = try connection.apiBaseURL(); configurationError = nil }
        catch { configurationError = error.localizedDescription; return }
        snapshot = AgentSessionSnapshot(provider: connection.kind, model: connection.model, connection: connection)
        save()
    }

    func send(_ prompt: String) {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isRunning, !prompt.isEmpty else { return }
        if snapshot.messages.isEmpty {
            let connection = AgentSettings.shared.connection
            do { _ = try connection.apiBaseURL(); configurationError = nil }
            catch { configurationError = error.localizedDescription; return }
            snapshot.provider = connection.kind; snapshot.model = connection.model; snapshot.connection = connection
        }
        snapshot.messages.append(ChatMessage(role: .user, blocks: [TranscriptBlock(kind: .text(prompt))]))
        snapshot.messages.append(ChatMessage(role: .assistant, isStreaming: true))
        let index = snapshot.messages.count - 1
        inputTokens = 0; outputTokens = 0; isRunning = true
        save()
        task = Task { [weak self] in
            guard let self else { return }
            do {
                guard isLocal else { throw AgentFailure("BYOK workspace tools currently support local projects. SSH tools are not yet available.") }
                guard persistenceError == nil else { throw AgentFailure("Resolve conversation storage before starting an agent turn.") }
                // Old snapshots used fixed official endpoints. Never redirect
                // their history to the newly selected custom connection.
                var connection = snapshot.connection ?? (snapshot.provider == .anthropic
                    ? AgentConnectionPreset.anthropic.connection : AgentConnectionPreset.openAI.connection)
                connection.model = snapshot.model
                let provider: any AgentProvider = try providerOverride ?? AgentSettings.shared.makeProvider(connection: connection)
                let tools = try AgentWorkspaceTools(root: workingDirectory)
                var definitions = AgentWorkspaceTools.definitions
                #if DIRECT_DISTRIBUTION && !APP_STORE
                if allowsCommands { definitions.append(AgentLocalCommand.definition) }
                #endif
                let runner = AgentRunner(provider: provider, tools: definitions, conversation: snapshot.conversation)
                try await runner.run(prompt, execute: { [weak self] call in
                    guard let self else { throw CancellationError() }
                    return try await self.execute(call, tools: tools)
                }, emit: { [weak self] event in
                    await self?.apply(event, index: index)
                })
                snapshot.messages[index].footnote = "\(inputTokens) input · \(outputTokens) output tokens"
            } catch {
                if Task.isCancelled || error is CancellationError {
                    snapshot.messages[index].footnote = "Stopped; completed edits were retained."
                } else { snapshot.messages[index].error = error.localizedDescription }
            }
            snapshot.messages[index].isStreaming = false
            snapshot.messages[index].isThinking = false
            isRunning = false; task = nil
            save()
        }
    }

    func stop() {
        task?.cancel()
        resolveApproval(false)
    }

    func resolveApproval(_ approved: Bool) {
        let continuation = decision
        decision = nil; approval = nil
        continuation?.resume(returning: approved)
    }

    private func approve(title: String, detail: String) async throws -> Bool {
        try Task.checkCancellation()
        let accepted = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                decision = continuation
                approval = AgentApproval(title: title, detail: detail)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolveApproval(false) }
        }
        try Task.checkCancellation()
        return accepted
    }

    private func execute(_ call: AgentToolCall, tools: AgentWorkspaceTools) async throws -> AgentToolResult {
        try Task.checkCancellation()
        // A failed checkpoint must stop side effects, not merely show a warning.
        guard persistenceError == nil else { throw AgentFailure("Conversation could not be saved; tool execution stopped.") }
        if ["create_file", "create_directory", "apply_edits"].contains(call.name) {
            let change = try await tools.prepare(call)
            if permissionMode == .ask {
                guard try await approve(title: "Apply workspace change?", detail: change.review) else {
                    return .init(id: call.id, output: "User declined this edit. Do not retry it.", isError: true)
                }
            }
            try Task.checkCancellation()
            let access = tools.access
            try AgentEditorCoordinator.shared.commit(change, access: access)
            snapshot.changes.append(change)
            return .init(id: call.id, output: "Applied \(change.path)." + (change.after.map { " Revision: " + AgentWorkspaceAccess.revision(Data($0.utf8)) } ?? ""))
        }
        #if DIRECT_DISTRIBUTION && !APP_STORE
        if call.name == "run_command" {
            guard allowsCommands, let command = call.arguments["command"].string,
                  let timeout = call.arguments["timeout_seconds"].integer else { throw AgentFailure("Local commands are disabled or invalid.") }
            guard try await approve(title: "Run local command?", detail: "Directory: \(workingDirectory.path)\nTimeout: \(timeout) seconds\n\n\(command)\n\nThis command runs with the app’s OS privileges and may access files outside the project.") else {
                return .init(id: call.id, output: "User declined this command. Do not retry it.", isError: true)
            }
            let output = try await AgentLocalCommand().run(command: command, root: workingDirectory, timeout: timeout)
            return .init(id: call.id, output: output)
        }
        #endif
        return try await .init(id: call.id, output: tools.read(call))
    }

    func revert(_ change: AgentFileChange) {
        guard !isRunning, let before = change.before, let after = change.after else { return }
        do {
            let access = try AgentWorkspaceAccess(root: workingDirectory)
            let inverse = AgentFileChange(path: change.path, before: after, after: before,
                revision: AgentWorkspaceAccess.revision(Data(after.utf8)))
            try AgentEditorCoordinator.shared.commit(inverse, access: access)
            snapshot.changes.removeAll { $0.id == change.id }
            save()
        } catch {
            snapshot.messages.append(ChatMessage(role: .assistant, error: error.localizedDescription))
        }
    }

    private func apply(_ event: AgentRunEvent, index: Int) {
        switch event {
        case .delta(let text):
            if !Task.isCancelled { snapshot.messages[index].liveText += text }
        case .response(let text):
            snapshot.messages[index].liveText = ""
            if !text.isEmpty { snapshot.messages[index].blocks.append(TranscriptBlock(kind: .text(text))) }
        case .tool(let call):
            let detail = call.arguments["path"].string ?? call.arguments["command"].string ?? ""
            snapshot.messages[index].blocks.append(TranscriptBlock(id: call.id, kind: .tool(.init(name: call.name, detail: detail))))
        case .result(let result):
            if let position = snapshot.messages[index].blocks.firstIndex(where: { $0.id == result.id }),
               case .tool(var tool) = snapshot.messages[index].blocks[position].kind {
                tool.output = String(result.output.prefix(64_000)); tool.isError = result.isError
                snapshot.messages[index].blocks[position].kind = .tool(tool)
            }
        case .usage(let input, let output): inputTokens += input; outputTokens += output
        case .checkpoint(let conversation): snapshot.conversation = conversation; save()
        }
    }

    private func save() {
        guard persists else { return }
        do { try AgentConversationStore.shared.get().save(snapshot, workspace: workspaceID); persistenceError = nil }
        catch {
            persistenceError = "Conversation storage: " + error.localizedDescription
            task?.cancel()
        }
    }
}
