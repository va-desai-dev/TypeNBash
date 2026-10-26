#if DIRECT_DISTRIBUTION && !APP_STORE
import SwiftUI
import Combine
import Sparkle

/// Compiled only into the DMG distribution. Sparkle reads its feed and
/// signing key from Info.plist (SUFeedURL, SUPublicEDKey) and checks on its
/// own schedule; this adds the manual check to the app menu.
enum AppUpdater {
    static let controller = SPUStandardUpdaterController(
        startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil
    )
}

/// Places "Check for Updates…" under About in the app menu.
struct UpdateCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesButton(updater: AppUpdater.controller.updater)
        }
    }
}

/// Mirrors the updater's readiness, so the item is disabled while a check runs.
private final class UpdaterState: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

private struct CheckForUpdatesButton: View {
    @StateObject private var state: UpdaterState
    private let updater: SPUUpdater

    init(updater: SPUUpdater) {
        self.updater = updater
        _state = StateObject(wrappedValue: UpdaterState(updater: updater))
    }

    var body: some View {
        Button("Check for Updates…", systemImage: "arrow.down.circle") {
            updater.checkForUpdates()
        }
        .labelStyle(.titleAndIcon)
        .disabled(!state.canCheckForUpdates)
    }
}
#endif
