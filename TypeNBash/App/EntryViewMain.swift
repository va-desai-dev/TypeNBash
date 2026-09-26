//
//  EntryView.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 9/19/26.
//

import SwiftUI

/// Owns only the welcome window and its inline setup forms.
struct EntryView: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var router = AppRouter()
    let windows: WorkspaceWindows

    var body: some View {
        ZStack {
            if router.route == .sshSetup {
                SSHConnectionSheet(windowSession: router.session, profileStore: router.profiles,
                                   onConnect: router.setupCompleted, isEmbedded: true,
                                   initialProfile: router.selectedSSHProfile, onCancel: router.cancelSetup)
            } else if router.route == .projectSetup {
                ProjectCreationSheet(windowSession: router.session, profileStore: router.profiles,
                                     store: router.projects.store, onOpen: router.setupCompleted,
                                     isEmbedded: true, onCancel: router.cancelSetup,
                                     initialProfileID: router.selectedSSHProfileID)
            } else {
                StartupDashboardView(router: router)
            }
        }
        .onChange(of: router.route) {
            guard router.route == .workspace else { return }
            let id = windows.insert(router)
            openWindow(id: WorkspaceWindows.workspaceID, value: id)
            dismissWindow(id: WorkspaceWindows.welcomeID)
        }
        .onAppear {
            let fresh = AppRouter()
            if windows.pendingSSHSetup {
                windows.pendingSSHSetup = false
                fresh.newSSHConnection()
            }
            else if windows.creatingNewProject {
                windows.creatingNewProject = false
                fresh.newProject()
            }
            router = fresh
        }
        // The window may already be open when the menu command fires.
        .onChange(of: windows.pendingSSHSetup) {
            guard windows.pendingSSHSetup else { return }
            windows.pendingSSHSetup = false
            router.newSSHConnection()
        }
        .onChange(of: windows.creatingNewProject) {
            guard windows.creatingNewProject else { return }
            windows.creatingNewProject = false
            router.newProject()
        }
        .onDisappear {
            // A handed-off session now belongs to its workspace window.
            if router.route != .workspace { router.close() }
        }
    }
}

struct StartupDashboardView: View {
    @Bindable var router: AppRouter

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image("TypeNBashLogo")
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 128, height: 128)
                Text("TypeNBash")
                    .font(.title2)
                    .fontWeight(.bold)
                Text("Version 1.0")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 32)

            Picker("Location", selection: $router.startupLocation) {
                ForEach(AppRouter.StartupLocation.allCases) { location in
                    Text(location.rawValue).tag(location)
                }
            }
            .controlSize(.extraLarge)
            .labelsHidden()
            .pickerStyle(.segmented)
            .disabled(router.projects.isBusy)

            VStack(spacing: 12) {
                HStack {
                    Text("Projects")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if router.startupLocation == .ssh {
                        Button("New Connection", systemImage: "plus", action: router.newSSHConnection)
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .disabled(router.projects.isBusy)
                    }
                }
                .frame(height: 24)
                List(router.recentProjects) { project in
                    Button { router.openProject(project) } label: {
                        RecentItemRow(
                            title: project.name,
                            path: "\(router.projects.label(for: project)) · \(project.directoryPath)",
                            isSelected: router.selectedProjectID == project.id
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Open \(project.name)")
                    .listRowSeparator(.hidden)
                }
                .listStyle(.plain)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if router.recentProjects.isEmpty {
                        ContentUnavailableView(
                            router.startupLocation == .local ? "No Local Projects" : "No SSH Projects",
                            systemImage: "folder",
                            description: Text("Create a project, or open Home to work without one.")
                        )
                    }
                }
                .disabled(router.projects.isBusy)
            }

            if let error = router.projects.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button("New Project", action: router.newProject)
                    .disabled(router.projects.isBusy)
                if router.projects.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { router.projects.cancel() }
                }
                Spacer()
                Button("Open Home", action: router.openHome)
                    .keyboardShortcut(.defaultAction)
                    .disabled(router.projects.isBusy)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 420, height: 780)
        .background(Color.card)
    }

}

struct RecentItemRow: View {
    let title: String
    let path: String
    let isSelected: Bool
    var symbol = "doc.text.fill"

    var body: some View {
        HStack {
            Image(systemName: symbol)
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .fontWeight(.medium)
                Text(path)
                    .font(.caption)
                    .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? .white : .primary)
    }
}
