//
//  TypeNBashApp.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

import Defaults
import SwiftUI

// 1. This reads your Xcode Organizer version automatically
public struct AppVersion {
    public static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as! String
    }

    public static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as! String
    }
}


@main
struct TypeNBashApp: App {
    @State private var windows = WorkspaceWindows()
    @State private var citeTex = CiteTexTargets.shared

    init() {
        AppDefaults.register()
        #if DIRECT_DISTRIBUTION && !APP_STORE
        _ = AppUpdater.controller  // starts Sparkle's scheduled checks at launch
        #endif
    }

    var body: some Scene {
        Window("TypeNBash", id: WorkspaceWindows.welcomeID) {
            EntryView(windows: windows)
                .tint(Color.accentColor)
                .preferredColorScheme(.dark)
        }
        .commandsRemoved()
        .windowLevel(.floating)
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .defaultPosition(.center)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {
                WelcomeWindowCommand()
            }
            CommandGroup(after: .newItem, addition: {
                SSHOpenCommand(windows: windows)
            })
            CommandGroup(after: .newItem, addition: {
                ProjectNewCommand(windows: windows)
            })
        }
        WindowGroup(
            id: WorkspaceWindows.workspaceID,
            for: UUID.self
        ) { $id in
            if let id, let router = windows.sessions[id] {
                ContentView(router: router)
                    .tint(Color.accentColor)
                    .preferredColorScheme(.dark)
                    .foregroundStyle(Color.foreground)
                    .onDisappear { windows.close(id) }
                    .navigationTitle(windows.workspaceName(router))
            }
        }
        .defaultSize(width: 1100, height: 720)
        .windowResizability(.contentSize)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
        .commands { ProjectCommands() }
        // The bundled website's guide; its own styles set the look.
        Window(HelpView.menuTitle, id: HelpView.windowID) {
            HelpView()
        }
        .defaultSize(width: 920, height: 640)
        .restorationBehavior(.disabled)
        .commands {
            HelpCommands()
            #if DIRECT_DISTRIBUTION && !APP_STORE
            UpdateCommands()
            #endif
        }
        // In the system menu bar so the target can be switched from Safari,
        // where no TypeNBash menu is showing. Available while a project has
        // a Markdown document selected, matching the citations inspector.
        MenuBarExtra("CiteTex", systemImage: "safari", isInserted: .constant(
            windows.sessions.values.contains {
                $0.session.activeProject != nil
                    && $0.session.fileBrowser.supportsCitations
            }
        )) {
            CiteTexMenu(targets: citeTex)
        }
        Settings {
            IDESettingsView()
                .background(AppTheme.shared.windowBackground)
                .toolbar(removing: .title)
                .tint(Color.accentColor)
                .preferredColorScheme(.dark)
        }
        .windowLevel(.floating)
        // Standard titlebar on purpose: `.hiddenTitleBar` makes the content view
        // full-size, which slides the panes' NSScrollViews under the titlebar and
        // AppKit then draws its hard scroll-edge pocket over them — something
        // `.scrollEdgeEffectHidden`/`.soft` can't reach.
    }
}

private struct WelcomeWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("New Window") {
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("n", modifiers: .command)
    }
}

private struct SSHOpenCommand: View {
    @Environment(\.openWindow) private var openWindow
    let windows: WorkspaceWindows

    var body: some View {
        Button("New SSH Host...") {
            windows.pendingSSHSetup = true
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("h", modifiers: .command)
    }
}
private struct ProjectNewCommand: View {
    @Environment(\.openWindow) private var openWindow
    let windows: WorkspaceWindows

    var body: some View {
        Button("New Project...") {
            windows.creatingNewProject = true
            openWindow(id: WorkspaceWindows.welcomeID)
        }
        .keyboardShortcut("p", modifiers: .command)
    }
}


/// The app chrome colors, with the user's overrides from Settings applied.
///
/// `@Observable`, so every view whose body reads one of the `Color` statics
/// below re-renders when the user picks a new color — no `.id()` reset that
/// would tear down terminals and editors.
@Observable
final class AppTheme {
    static let shared = AppTheme()

    static let defaultCard = Color(red: 11/255, green: 10/255, blue: 10/255)
    static let defaultAccent = Color(red: 184/255, green: 151/255, blue: 94/255)
    static let defaultForeground = Color(red: 240/255, green: 234/255, blue: 214/255)
    static let defaultSecondary = Color(red: 126/255, green: 122/255, blue: 112/255)

    // The stored `#RRGGBBAA` override codes; nil keeps the default color.
    private var cardCode: String?
    private var accentCode: String?
    private var foregroundCode: String?
    private var secondaryCode: String?

    /// Whether the window is painted with `gradientCard` rather than the flat card.
    private(set) var gradientBackground = false
    var card: Color { Self.color(cardCode) ?? Self.defaultCard }
    var accent: Color { Self.color(accentCode) ?? Self.defaultAccent }
    var foreground: Color { Self.color(foregroundCode) ?? Self.defaultForeground }
    var secondary: Color { Self.color(secondaryCode) ?? Self.defaultSecondary }

    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    private init() {
        reload()
        // Settings writes the overrides through `@AppStorage`; follow along.
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    /// Re-reads the overrides, assigning only what changed so an unrelated
    /// defaults write doesn't invalidate every themed view.
    private func reload() {
        let defaults = UserDefaults.standard
        let card = defaults.string(forKey: DefaultKeys.backgroundColor.rawValue)
        let accent = defaults.string(forKey: DefaultKeys.accentColor.rawValue)
        let foreground = defaults.string(forKey: DefaultKeys.textColor.rawValue)
        let secondary = defaults.string(forKey: DefaultKeys.secondaryColor.rawValue)
        if cardCode != card { cardCode = card }
        if accentCode != accent { accentCode = accent }
        if foregroundCode != foreground { foregroundCode = foreground }
        if secondaryCode != secondary { secondaryCode = secondary }
        let gradient = defaults.bool(forKey: DefaultKeys.gradientBackground.rawValue)
        if gradientBackground != gradient { gradientBackground = gradient }
    }

    var gradientCard: LinearGradient {
        .init(colors: [card, card.mix(with: foreground, by: 0.134)],
              startPoint: .bottomLeading,
              endPoint: .topTrailing)
    }

    /// The window's backdrop: one gradient spanning every column, or the flat card.
    var windowBackground: AnyShapeStyle {
        gradientBackground ? AnyShapeStyle(gradientCard) : AnyShapeStyle(card)
    }

    /// Fill for the panes and toolbar. Clear while the gradient is on, so the
    /// single window-wide gradient shows through instead of one per pane.
    var paneBackground: Color {
        gradientBackground ? .clear : .card
    }

    private static func color(_ code: String?) -> Color? {
        code.flatMap { NSColor.sRGB(colorCode: $0) }.map { Color(nsColor: $0) }
    }
}

extension Color {
    static var card: Color { AppTheme.shared.card }
    static var accentColor: Color { AppTheme.shared.accent }
    static var foreground: Color { AppTheme.shared.foreground }
    static var secondary: Color { AppTheme.shared.secondary }
}
