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
                                     isEmbedded: true, onCancel: router.cancelSetup)
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

            if #available(macOS 27.0, *) {
                Picker("Selection", selection: $router.startupMode) {
                    ForEach(AppStartupModes.allCases.filter(with: .init(arrayLiteral: .free, .projectNew, .ssh))) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .controlSize(.extraLarge)
                .labelsHidden()
                .pickerStyle(.tabs)
                .disabled(router.projects.isBusy)
            } else {
                Picker("Selection", selection: $router.startupMode) {
                    ForEach(AppStartupModes.allCases.filter(with: .init(arrayLiteral: .free, .projectNew, .ssh))) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .controlSize(.extraLarge)
                .labelsHidden()
                .pickerStyle(.segmented)
                .disabled(router.projects.isBusy)
            }
            if router.startupMode == .ssh {
                List(selection: $router.selectedSSHProfileID) {
                    ForEach(router.profiles.profiles) { profile in
                        RecentItemRow(title: profile.name, path: profile.destination,
                                      isSelected: router.selectedSSHProfileID == profile.id,
                                      symbol: "network")
                        .tag(profile.id)
                    }
                }
                .listStyle(.plain)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if router.profiles.profiles.isEmpty {
                        ContentUnavailableView("No Saved Connections", systemImage: "network",
                                               description: Text("Choose New Connection to add an SSH host."))
                    }
                }
            } else {
                List(selection: $router.selectedProjectID) {
                    ForEach(router.projects.store.recents) { project in
                        RecentItemRow(
                            title: project.name,
                            path: "\(router.projects.label(for: project)) · \(project.directoryPath)",
                            isSelected: router.selectedProjectID == project.id
                        )
                        .tag(project.id)
                    }
                }
                .listStyle(.plain)
                .background(Color(.controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay {
                    if router.projects.store.projects.isEmpty {
                        ContentUnavailableView("No Saved Projects", systemImage: "folder",
                                               description: Text("Choose New Project to save a workspace folder."))
                    }
                }
                .disabled(router.projects.isBusy)
                .onChange(of: router.selectedProjectID) { router.startupMode = .projectOpen }

            }

            if router.startupMode != .ssh, let error = router.projects.error {
                Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                if router.startupMode == .ssh {
                    Button("New Connection", action: router.newSSHConnection)
                } else {
                    Button("New Project") { router.launch(.projectNew) }
                        .disabled(router.projects.isBusy)
                }
                if router.projects.isBusy {
                    ProgressView().controlSize(.small)
                    Button("Cancel", role: .cancel) { router.projects.cancel() }
                }
                Spacer()
                Button(launchTitle) { router.launch(router.startupMode) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(router.projects.isBusy || (router.startupMode == .ssh && router.selectedSSHProfile == nil))
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 20)
        .frame(width: 420, height: 780)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var launchTitle: String {
        switch router.startupMode {
            case .free: "Work Locally"
            case .ssh: "Connect over SSH"
            case .projectNew: "New Project…"
            case .projectOpen: router.selectedProjectID == nil ? "Choose Project…" : "Open Selected Project"
        }
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
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .listRowBackground(isSelected ? Color.accentColor : Color.clear)
        .foregroundStyle(isSelected ? .white : .primary)
    }
}
