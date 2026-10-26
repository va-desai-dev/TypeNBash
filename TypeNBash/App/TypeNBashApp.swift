//
//  TypeNBashApp.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

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
                .background(Color.card)
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


extension Color {
    static let card = Color(red: 11/255, green: 10/255, blue: 10/255)
    static let accentColor = Color(red: 184/255, green: 151/255, blue: 94/255)
    static let foreground = Color(red: 240/255, green: 234/255, blue: 214/255)
}
