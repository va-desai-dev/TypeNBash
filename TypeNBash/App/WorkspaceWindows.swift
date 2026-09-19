import Foundation
import Observation

/// Retains prepared sessions while their independent workspace windows are open.
@MainActor
@Observable
final class WorkspaceWindows {
    static let welcomeID = "welcome"
    static let workspaceID = "workspace"
    private(set) var sessions: [UUID: AppRouter] = [:]
    /// Set by the menu command so the welcome window opens straight into SSH setup.
    var pendingSSHSetup = false
    var creatingNewProject = false

    func insert(_ router: AppRouter) -> UUID {
        let id = UUID()
        sessions[id] = router
        return id
    }

    func close(_ id: UUID) {
        sessions.removeValue(forKey: id)?.close()
    }
}
