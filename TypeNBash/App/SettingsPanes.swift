//
//  SettingsPanes.swift
//  TypeNBash
//
//  The management panes of the Settings window. Each works directly on the
//  app-wide store the welcome window and workspaces already use, so an edit
//  here is what every other window sees.
//

import AppKit
import SwiftUI

// MARK: - SSH Connections

struct SSHConnectionsSettingsPane: View {
    @Bindable var profiles: SSHProfileStore = .shared
    let projects: ProjectStore = .shared

    @State private var editing: SSHConnectionProfile?
    @State private var profileToDelete: SSHConnectionProfile?
    /// Re-read after a password is forgotten; the Keychain isn't observable.
    @State private var passwordRevision = 0

    var body: some View {
        Form {
            Section {
                if profiles.profiles.isEmpty {
                    Text("No saved connections. Add one from the welcome window with New SSH Host….")
                        .foregroundStyle(.secondary)
                }
                ForEach(profiles.profiles) { profile in
                    row(for: profile)
                }
            } header: {
                Text("Saved Connections")
            } footer: {
                Text("New connections are added from the welcome window, where they're tested before saving.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .sheet(item: $editing) { profile in
            SSHProfileEditor(profile: profile) { profiles.update($0) }
        }
        .confirmationDialog("Delete saved connection?", isPresented: Binding(
            get: { profileToDelete != nil },
            set: { if !$0 { profileToDelete = nil } }
        ), titleVisibility: .visible) {
            if let profile = profileToDelete {
                Button("Delete \(profile.name)", role: .destructive) { profiles.delete(profile) }
            }
        } message: {
            if let profile = profileToDelete {
                Text(deleteMessage(for: profile))
            }
        }
    }

    private func row(for profile: SSHConnectionProfile) -> some View {
        let hasPassword = { _ = passwordRevision; return profiles.hasPassword(for: profile.id) }()
        return HStack {
            Image(systemName: "network").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(profile.name).fontWeight(.medium)
                Text(details(for: profile))
                    .font(.caption).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer()
            if hasPassword {
                Button("Forget Password") {
                    profiles.forgetPassword(for: profile.id)
                    passwordRevision += 1
                }
                .help("Remove the saved password from Keychain. Key or agent sign-in is used instead.")
            }
            Button("Edit…") { editing = profile }
            Button(role: .destructive) { profileToDelete = profile } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Delete this connection")
        }
    }

    private func details(for profile: SSHConnectionProfile) -> String {
        var parts = [profile.destination]
        if let port = profile.port { parts[0] += ":\(port)" }
        if let key = profile.identityFile { parts.append(key.lastPathComponent) }
        if let root = profile.remoteRoot, !root.isEmpty { parts.append(root) }
        return parts.joined(separator: " · ")
    }

    private func deleteMessage(for profile: SSHConnectionProfile) -> String {
        let dependents = projects.projects(referencing: profile.id)
        let base = "Its saved password is removed from Keychain."
        switch dependents.count {
        case 0: return base
        case 1: return base + " The project “\(dependents[0].name)” opens over it and will no longer open."
        default: return base + " \(dependents.count) projects open over it and will no longer open."
        }
    }
}

/// Edits the details of a saved connection. The password is left alone.
private struct SSHProfileEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State private var profile: SSHConnectionProfile
    @State private var portText: String
    let onSave: (SSHConnectionProfile) -> Void

    init(profile: SSHConnectionProfile, onSave: @escaping (SSHConnectionProfile) -> Void) {
        _profile = State(initialValue: profile)
        _portText = State(initialValue: profile.port.map(String.init) ?? "")
        self.onSave = onSave
    }

    private var trimmedHost: String { profile.host.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var port: Int?? {
        let text = portText.trimmingCharacters(in: .whitespaces)
        if text.isEmpty { return .some(nil) }
        guard let value = Int(text), (1...65535).contains(value) else { return nil }
        return .some(value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                TextField("Name", text: $profile.name)
                TextField("Host", text: $profile.host)
                TextField("User", text: Binding(
                    get: { profile.user ?? "" },
                    set: { profile.user = $0.isEmpty ? nil : $0 }))
                TextField("Port", text: $portText, prompt: Text("22"))
                TextField("Default Folder", text: Binding(
                    get: { profile.remoteRoot ?? "" },
                    set: { profile.remoteRoot = $0.isEmpty ? nil : $0 }))
                if port == nil {
                    Text("Port must be a number from 1 to 65535.")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save") {
                    guard let port else { return }
                    var saved = profile
                    saved.host = trimmedHost
                    saved.port = port
                    let name = saved.name.trimmingCharacters(in: .whitespacesAndNewlines)
                    saved.name = name.isEmpty ? saved.destination : name
                    onSave(saved)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedHost.isEmpty || port == nil)
            }
            .padding()
        }
        .frame(width: 400)
    }
}

// MARK: - Projects

struct ProjectsSettingsPane: View {
    @Bindable var store: ProjectStore = .shared
    @Bindable var profiles: SSHProfileStore = .shared

    @State private var projectToDelete: Project?

    var body: some View {
        Form {
            Section {
                if store.projects.isEmpty {
                    Text("No saved projects.").foregroundStyle(.secondary)
                }
                ForEach(store.alphabetized) { project in
                    row(for: project)
                }
            } header: {
                Text("Saved Projects")
            } footer: {
                Text("Removing a project only takes it off TypeNBash's list. Its folder and files are untouched.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Remove saved project?", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        ), titleVisibility: .visible) {
            if let project = projectToDelete {
                Button("Remove \(project.name)", role: .destructive) { store.delete(project) }
            }
        } message: {
            Text("The folder and its files will remain untouched.")
        }
    }

    private func row(for project: Project) -> some View {
        let connection = project.sshProfileID.flatMap { id in profiles.profiles.first { $0.id == id } }
        let isMissingConnection = !project.isLocal && connection == nil
        return HStack {
            Image(systemName: project.isLocal ? "folder" : "network").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name).fontWeight(.medium)
                Text(project.directoryPath)
                    .font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 4) {
                    if isMissingConnection {
                        Label("Missing SSH connection", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    } else {
                        Text(connection?.destination ?? "This Mac")
                    }
                    Text("· opened \(project.lastOpened, format: .relative(presentation: .named))")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if project.isLocal {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([project.localDirectoryURL])
                }
            }
            Button(role: .destructive) { projectToDelete = project } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from saved projects")
        }
    }
}

// MARK: - Source Control

struct SourceControlSettingsPane: View {
    @Bindable var profiles: SSHProfileStore = .shared
    @State private var account = GitHubAccountModel()
    /// Mirrors `GitHubLending`, which lives in per-host user defaults keys.
    @State private var lending: [UUID: Bool] = [:]

    var body: some View {
        Form {
            Section("GitHub Account") {
                GitHubAccountView(model: account)
            }
            Section {
                if profiles.profiles.isEmpty {
                    Text("No saved SSH connections.").foregroundStyle(.secondary)
                }
                ForEach(profiles.profiles) { profile in
                    Toggle(isOn: binding(for: profile.id)) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(profile.name)
                            Text(profile.destination)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("Use My GitHub Sign-In on Remote Hosts")
            } footer: {
                Text("A host that's turned on can push and pull with your GitHub sign-in, in Source Control and in its terminals. The token is handed out per request and never stored on the host. Terminals already open keep their current setting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: reloadLending)
        .onChange(of: profiles.profiles) { reloadLending() }
    }

    private func binding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { lending[id] ?? false },
            set: {
                GitHubLending.setEnabled($0, for: id)
                lending[id] = $0
            }
        )
    }

    private func reloadLending() {
        lending = Dictionary(uniqueKeysWithValues: profiles.profiles.map {
            ($0.id, GitHubLending.isEnabled(for: $0.id))
        })
    }
}
