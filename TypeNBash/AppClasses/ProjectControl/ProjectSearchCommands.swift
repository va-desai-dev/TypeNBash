import SwiftUI

struct ProjectCommands: Commands {
    @FocusedValue(\.projectSearch) private var projSearch

    var body: some Commands {
        CommandGroup(replacing: .toolbar) {
            Button("Find Items") { projSearch?.reveal() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(projSearch?.session.mode != .project)
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
