//
//  SettingsView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/25/26.
//

import SwiftUI

enum IDESettingsTab: String, CaseIterable, Identifiable {
    case editor = "Text Editor"
    case connections = "SSH Connections"
    case projects = "Projects"
    case sourceControl = "Source Control"

    var id: String { self.rawValue }

    var iconName: String {
        switch self {
        case .editor: return "doc.text.magnifyingglass"
        case .connections: return "network"
        case .projects: return "folder"
        case .sourceControl: return "arrow.triangle.branch"
        }
    }
}


/// The master settings window. Every pane works on the same user defaults and
/// stores the in-window menus and welcome window already use, so the two stay
/// in step.
struct IDESettingsView: View {
    @State private var selectedTab: IDESettingsTab = .editor

    var body: some View {
        NavigationSplitView {
            List(IDESettingsTab.allCases, selection: $selectedTab) { tab in
                NavigationLink(value: tab) {
                    Label(tab.rawValue, systemImage: tab.iconName)
                        .font(.body)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 160, idealWidth: 180)
        } detail: {
            Group {
                switch selectedTab {
                case .editor:
                    editorSettingsPane
                case .connections:
                    SSHConnectionsSettingsPane()
                case .projects:
                    ProjectsSettingsPane()
                case .sourceControl:
                    SourceControlSettingsPane()
                }
            }
            .frame(minWidth: 420, idealWidth: 460)
        }
        .frame(width: 720, height: 520) // Enforces stable IDE preference proportions
    }

    // MARK: - Editor Settings Pane
    private var editorSettingsPane: some View {
        Form {
            Section("Editor Options") {
                EditorOptionsControls()
            }
        }
        .formStyle(.grouped) // Provides native inset panel background contrast
    }
}
