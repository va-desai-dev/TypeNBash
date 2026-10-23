import SwiftUI

struct ProjectSearchCommands: Commands {
    @FocusedValue(\.projectSearch) private var search
    var body: some Commands {
        CommandMenu("Find") {
            Button("Find in Project") { search?.reveal() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(search?.session.mode != .project)
        }
    }
}

private struct ProjectSearchFocusKey: FocusedValueKey { typealias Value = ProjectSearchModel }
extension FocusedValues {
    var projectSearch: ProjectSearchModel? {
        get { self[ProjectSearchFocusKey.self] }
        set { self[ProjectSearchFocusKey.self] = newValue }
    }
}
