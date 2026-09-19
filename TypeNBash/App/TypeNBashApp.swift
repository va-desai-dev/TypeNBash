//
//  TypeNBashApp.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/12/26.
//

import SwiftUI

@main
struct TypeNBashApp: App {
    @State private var windows = WorkspaceWindows()

    var body: some Scene {
        Window("Welcome to TypeNBash", id: WorkspaceWindows.welcomeID) {
            EntryView(windows: windows)
                .tint(Color.accentColor)
                .preferredColorScheme(.dark)
        }
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

        WindowGroup("TypeNBash", id: WorkspaceWindows.workspaceID, for: UUID.self) { $id in
            if let id, let router = windows.sessions[id] {
                ContentView(router: router)
                    .tint(Color.accentColor)
                    .preferredColorScheme(.dark)
                    .foregroundStyle(Color.foreground)
                    .onDisappear { windows.close(id) }
            }
        }
        .defaultSize(width: 1100, height: 720)
        .defaultLaunchBehavior(.suppressed)
        .restorationBehavior(.disabled)
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
