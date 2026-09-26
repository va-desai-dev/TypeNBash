//
//  SettingsView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/25/26.
//

import SwiftUI

enum IDESettingsTab: String, CaseIterable, Identifiable {
    case editor = "Editor"
    case connections = "Remotes"
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
        HStack {
            List(IDESettingsTab.allCases, id: \.self, selection: $selectedTab) { tab in
                Label(tab.rawValue, systemImage: tab.iconName)
            }
            .listStyle(.sidebar)
            .scrollContentBackground(.hidden)
            .frame(width: 180)
            Group {
                switch selectedTab {
                case .editor:
                        EditorOptionsControls()
                case .connections:
                    SSHConnectionsSettingsPane()
                            .scrollContentBackground(.hidden)
                case .projects:
                    ProjectsSettingsPane()
                            .scrollContentBackground(.hidden)
                case .sourceControl:
                    SourceControlSettingsPane()
                            .scrollContentBackground(.hidden)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: 720, height: 520)
        .toolbarBackground(.hidden, for: .windowToolbar)
    }
}
