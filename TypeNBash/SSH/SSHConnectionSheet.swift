import AppKit
import Foundation
import SwiftUI

struct SSHConnectionSheet: View {
    @Environment(\.dismiss) private var dismiss

    let windowSession: WindowSession
    let profileStore: SSHProfileStore
    var onConnect: () -> Void = {}
    var isEmbedded = false
    var initialProfile: SSHConnectionProfile?
    var onCancel: (() -> Void)?

    @State private var host = ""
    @State private var user = ""
    @State private var port = "22"
    @State private var authenticationStyle = AuthenticationStyle.keyOrAgent
    @State private var identityPath = ""
    @State private var password = ""
    @State private var remoteRoot = ""
    @State private var connectionError: String?
    @State private var isConnecting = false
    @State private var connectionTask: Task<Void, Never>?
    @State private var editingProfileID: UUID?
    @State private var saveProfile = true
    @State private var rememberPassword = false
    @FocusState private var focusedField: Field?

    private var openFileURL: some View {
        Button {
            chooseIdentityFile()
        } label: {
            Label("Choose Key", systemImage: "key.horizontal")
        }
    }

    /// Opens an NSOpenPanel that shows hidden files and starts in ~/.ssh, so the
    /// private key can be picked directly — SwiftUI's `.fileImporter` can do neither.
    private func chooseIdentityFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = true
        panel.message = "Choose your SSH private key"
        panel.prompt = "Use Key"

        let sshDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh", isDirectory: true)
        if FileManager.default.fileExists(atPath: sshDirectory.path) {
            panel.directoryURL = sshDirectory
        }

        if panel.runModal() == .OK, let url = panel.url {
            identityPath = url.path
        }
    }

    private enum Field: Hashable {
        case host
    }

    private enum AuthenticationStyle: String, CaseIterable, Identifiable {
        case keyOrAgent
        case password

        var id: Self { self }

        var title: String {
            switch self {
            case .keyOrAgent: "Key / Agent"
            case .password: "Password"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            connectionForm
            Divider()
            actions
        }
        .frame(width: isEmbedded ? 420 : 500, height: isEmbedded ? 780 : 540)
        .background(isEmbedded ? Color(nsColor: .windowBackgroundColor) : Color.card)
        .foregroundStyle(isEmbedded ? Color.primary : Color.foreground)
        .tint(Color.accentColor)
        .preferredColorScheme(isEmbedded ? nil : .dark)
        .onAppear {
            if let initialProfile { apply(initialProfile) }
            focusedField = .host
        }
        .onDisappear { connectionTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "network")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.14), in: .rect(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text("Connect over SSH")
                    .font(.headline)
                Text("The entire TypeNBash window will use this remote workspace.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()
        }
        .padding(16)
    }

    private var connectionForm: some View {
        Form {
            if !isEmbedded && !profileStore.profiles.isEmpty {
                Section("Saved connections") {
                    ForEach(profileStore.profiles) { profile in
                        HStack(spacing: 8) {
                            Button {
                                apply(profile)
                            } label: {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(profile.name)
                                        .fontWeight(.medium)
                                    Text(profile.destination)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)

                            if editingProfileID == profile.id {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.accentColor)
                            }

                            Button(role: .destructive) {
                                deleteSavedProfile(profile)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                        .disabled(isConnecting)
                    }
                }
            }

            Section("Connection") {
                TextField("Host or SSH config alias", text: $host)
                    .focused($focusedField, equals: .host)
                    .disabled(isConnecting)

                TextField("User (optional)", text: $user)
                    .disabled(isConnecting)

                TextField("Port", text: $port)
                    .disabled(isConnecting)
            }

            Section("Authentication") {
                Picker("Method", selection: $authenticationStyle) {
                    ForEach(AuthenticationStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(isConnecting)

                HStack {
                    TextField("Identity file (optional)", text: $identityPath)
                        .disabled(isConnecting)
                    Spacer()
                    openFileURL
                }

                if authenticationStyle == .password {
                    SecureField("Password or key passphrase", text: $password)
                        .disabled(isConnecting)

                    Text("The secret is discarded as soon as the shared SSH connection authenticates.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Uses the selected identity, SSH config, and your running agent.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !identityPathIsValid {
                    Label("The identity file does not exist.", systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                }
            }

            Section("Workspace") {
                TextField("Remote root (optional)", text: $remoteRoot)
                    .disabled(isConnecting)

                Text("Leave the workspace blank to open the remote home directory.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Save") {
                Toggle("Save this connection", isOn: $saveProfile)
                    .disabled(isConnecting)
                if authenticationStyle == .password {
                    Toggle("Remember password in Keychain", isOn: $rememberPassword)
                        .disabled(isConnecting || !saveProfile)
                }
            }

            if let connectionError {
                Section {
                    Label(connectionError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(Color.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(isEmbedded ? Color.clear : Color.black)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(footerNote)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer()

            if case .ssh = windowSession.location {
                Button("Disconnect") {
                    connectionTask?.cancel()
                    windowSession.disconnectToLocal()
                    dismiss()
                }
            }

            Button("Cancel", role: .cancel, action: cancel)

            Button(action: beginConnection) {
                if isConnecting {
                    HStack(spacing: 6) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Connecting")
                    }
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.accentColor)
            .disabled(!isValid || isConnecting)
            .keyboardShortcut(.defaultAction)
        }
        .padding(16)
        .background(isEmbedded ? Color(nsColor: .windowBackgroundColor) : Color.card)
    }

    private var isValid: Bool {
        !trimmedHost.isEmpty &&
        parsedPort != nil &&
        identityPathIsValid &&
        (authenticationStyle != .password || !password.isEmpty)
    }

    private var footerNote: String {
        switch authenticationStyle {
        case .keyOrAgent:
            "Uses OpenSSH config, known hosts, and key or agent credentials."
        case .password:
            "Password authentication requires a previously trusted host key."
        }
    }

    private var trimmedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var parsedPort: Int? {
        guard let value = Int(port), (1...65_535).contains(value) else { return nil }
        return value
    }

    private var identityFile: URL? {
        let path = identityPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    private var identityPathIsValid: Bool {
        guard let identityFile else { return true }
        return FileManager.default.fileExists(atPath: identityFile.path)
    }

    private func apply(_ profile: SSHConnectionProfile) {
        editingProfileID = profile.id
        host = profile.host
        user = profile.user ?? ""
        port = profile.port.map(String.init) ?? "22"
        identityPath = profile.identityFile?.path ?? ""
        remoteRoot = profile.remoteRoot ?? ""
        connectionError = nil
        saveProfile = true
        if let savedPassword = profileStore.password(for: profile.id) {
            authenticationStyle = .password
            password = savedPassword
            rememberPassword = true
        } else {
            authenticationStyle = .keyOrAgent
            password = ""
            rememberPassword = false
        }
    }

    private func deleteSavedProfile(_ profile: SSHConnectionProfile) {
        profileStore.delete(profile)
        if editingProfileID == profile.id { editingProfileID = nil }
    }

    private func beginConnection() {
        guard let parsedPort else { return }
        let trimmedUser = user.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedRoot = remoteRoot.trimmingCharacters(in: .whitespacesAndNewlines)
        let profile = SSHConnectionProfile(
            id: editingProfileID ?? UUID(),
            name: trimmedHost,
            host: trimmedHost,
            user: trimmedUser.isEmpty ? nil : trimmedUser,
            port: parsedPort == 22 ? nil : parsedPort,
            identityFile: identityFile,
            remoteRoot: trimmedRoot.isEmpty ? nil : trimmedRoot
        )
        if saveProfile {
            let secret = (authenticationStyle == .password && rememberPassword) ? password : nil
            profileStore.save(profile, password: secret)
            editingProfileID = profile.id
        }
        let authentication: SSHAuthentication = switch authenticationStyle {
        case .keyOrAgent:
            .keyOrAgent
        case .password:
            .password(password)
        }

        connectionError = nil
        isConnecting = true
        connectionTask = Task {
            await windowSession.connect(
                to: profile,
                authentication: authentication
            )
            guard !Task.isCancelled else { return }

            isConnecting = false
            switch windowSession.state {
            case .remote(let connectedProfile) where connectedProfile.id == profile.id:
                onConnect()
                if !isEmbedded { dismiss() }
            case .failed(let failedProfile, let message) where failedProfile.id == profile.id:
                connectionError = message
            default:
                connectionError = "The connection ended before the remote workspace became active."
            }
        }
    }

    private func cancel() {
        connectionTask?.cancel()
        if let onCancel { onCancel() } else { dismiss() }
    }
}

#Preview {
    SSHConnectionSheet(windowSession: WindowSession(), profileStore: SSHProfileStore())
}
