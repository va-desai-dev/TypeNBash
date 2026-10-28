import Foundation
import SwiftData

@Model
final class StoredAgentConversation {
    @Attribute(.unique) var id: UUID
    var workspace: String
    var updated: Date
    var snapshot: Data
    init(id: UUID, workspace: String, snapshot: Data) {
        self.id = id; self.workspace = workspace; self.snapshot = snapshot; updated = .now
    }
}

nonisolated struct AgentSessionSnapshot: Codable, Sendable {
    var id = UUID()
    var provider: AgentProviderKind
    var model: String
    var connection: AgentConnection?
    var messages: [ChatMessage] = []
    var conversation = AgentConversation()
    var changes: [AgentFileChange] = []
}

@MainActor
final class AgentConversationStore {
    static let shared: Result<AgentConversationStore, Error> = Result { try AgentConversationStore() }
    private let container: ModelContainer
    init(inMemory: Bool = false) throws {
        container = try ModelContainer(for: StoredAgentConversation.self,
            configurations: ModelConfiguration("AgentConversations", isStoredInMemoryOnly: inMemory))
    }
    func latest(workspace: String) throws -> AgentSessionSnapshot? {
        var query = FetchDescriptor<StoredAgentConversation>(predicate: #Predicate { $0.workspace == workspace },
            sortBy: [SortDescriptor(\.updated, order: .reverse)])
        query.fetchLimit = 1
        guard let record = try container.mainContext.fetch(query).first else { return nil }
        return try JSONDecoder().decode(AgentSessionSnapshot.self, from: record.snapshot)
    }
    func save(_ snapshot: AgentSessionSnapshot, workspace: String) throws {
        let id = snapshot.id
        let data = try JSONEncoder().encode(snapshot)
        let query = FetchDescriptor<StoredAgentConversation>(predicate: #Predicate { $0.id == id })
        if let record = try container.mainContext.fetch(query).first {
            record.snapshot = data; record.updated = .now
        } else { container.mainContext.insert(StoredAgentConversation(id: id, workspace: workspace, snapshot: data)) }
        try container.mainContext.save()
    }
}

/// Registered models are weak so closing a window releases its editor. All
/// open windows participate in the last-moment conflict check and refresh.
@MainActor
final class AgentEditorCoordinator {
    static let shared = AgentEditorCoordinator()
    private let models = NSHashTable<FileBrowserModel>.weakObjects()
    func register(_ model: FileBrowserModel) { models.add(model) }
    func commit(_ change: AgentFileChange, access: any AgentFileAccess) async throws {
        let url = access.root.appendingPathComponent(change.path).standardizedFileURL
        // Remote paths are the host's, so they are compared only with editors
        // on the same connection and never resolved against this Mac.
        let remote = (access as? AgentRemoteWorkspaceAccess)?.fileSystem
        let open = models.allObjects.filter { model in
            guard let remote else {
                return !(model.fileSystem is SSHWorkspaceFileSystem)
                    && model.selectedFile?.resolvingSymlinksInPath().standardizedFileURL == url
            }
            return model.fileSystem === remote && model.selectedFile?.standardizedFileURL == url
        }
        for model in open {
            guard !model.hasUnsavedChanges, !model.isSaving else { throw AgentFailure("This file has unsaved edits or is being saved in an editor window.") }
            switch model.preview {
            case .text, .markdown: break
            default: throw AgentFailure("Close this file’s preview before allowing the agent to edit it.")
            }
        }
        try await access.commit(change)
        for model in models.allObjects { model.refresh() }
        // A remote commit suspends; never reload over typing that began meanwhile.
        for model in open where !model.hasUnsavedChanges && !model.isSaving {
            model.select(WorkspaceFileEntry(url: url, isDirectory: false, byteCount: nil))
        }
    }
}
