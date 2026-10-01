import SwiftUI

struct ProjectCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectPickerModel
    @State private var projectToDelete: Project?

    private let onOpen: () -> Void
    private let isEmbedded: Bool
    private let onCancel: (() -> Void)?

    init(windowSession: WindowSession, profileStore: SSHProfileStore,
         store: ProjectStore? = nil, onOpen: @escaping () -> Void = {},
         isEmbedded: Bool = false, onCancel: (() -> Void)? = nil,
         initialProfileID: UUID? = nil) {
        let model = ProjectPickerModel(session: windowSession, profiles: profileStore, store: store)
        model.setupMode = isEmbedded ? .newFolder : .openFolder
        if isEmbedded { model.selectedProfileID = initialProfileID }
        _model = State(initialValue: model)
        self.onOpen = onOpen
        self.isEmbedded = isEmbedded
        self.onCancel = onCancel
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.setupMode == .openFolder ? "Open a Project" : "New Project").font(.headline)
                    Text("Choose a workspace on this Mac or an SSH host.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                if !isEmbedded && !model.store.projects.isEmpty {
                    Section("Saved projects") {
                        ForEach(model.store.projects) { project in
                            HStack {
                                Button {
                                    model.openSaved(project) { onOpen(); if !isEmbedded { dismiss() } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(project.name).fontWeight(.medium)
                                        Text("\(model.label(for: project)) · \(project.directoryPath)")
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                Button(role: .destructive) { projectToDelete = project } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                            .disabled(model.isBusy)
                        }
                    }
                }
                Section("Project") {
                    Picker("Action", selection: $model.setupMode) {
                        ForEach(ProjectPickerModel.SetupMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode)
                        }
                    }
                    .disabled(model.isBusy)
                    Picker("Location", selection: Binding(
                        get: { model.selectedProfileID },
                        set: { model.selectedProfileID = $0; model.locationChanged() }
                    )) {
                        Text("This Mac").tag(nil as UUID?)
                        ForEach(model.availableProfiles) { profile in
                            Text(profile.destination).tag(Optional(profile.id))
                        }
                    }
                    .disabled(model.isBusy)
                    TextField(model.setupMode == .newFolder ? "Project folder name" : "Name (defaults to folder name)", text: $model.name)
                        .disabled(model.isBusy)
                    HStack {
                        TextField(model.setupMode == .newFolder ? "Parent directory" : "Project directory or definition", text: $model.directoryPath)
                        Button("Choose Folder", systemImage: "folder") { model.chooseFolder() }
                    }
                    .disabled(model.isBusy)
                    if model.setupMode != .openFolder {
                        TextField("Output folder", text: $model.outputDirectory)
                            .disabled(model.isBusy)
                        Text(model.setupMode == .newFolder
                             ? "Creates a folder with your project name and a portable project definition. The output folder is created when needed."
                             : "Adds a portable project definition to this folder. Existing files remain in place.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if model.selectedProfileID != nil {
                        SecureField("Password or key passphrase (if needed)", text: $model.password)
                            .disabled(model.isBusy)
                        Text("Uses your active connection, saved password, or SSH key. A password entered here is used only for this connection.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.availableProfiles.isEmpty {
                        Text("Add a connection using the SSH button to open remote projects.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let error = model.error, !model.isBrowsing {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red).textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            Divider()
            HStack {
                Button("Cancel", role: .cancel) { model.cancel(); if let onCancel { onCancel() } else { dismiss() } }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button(model.setupMode == .openFolder ? "Open Project" : "Create Project") { model.saveAndOpen { onOpen(); if !isEmbedded { dismiss() } } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canOpen)
            }
            .padding(16)
        }
        .frame(width: isEmbedded ? 420 : 560, height: isEmbedded ? 780 : 580)
        .background(Color.card)
        .foregroundStyle(isEmbedded ? Color.primary : Color.foreground)
        .tint(Color.accentColor)
        .preferredColorScheme(isEmbedded ? nil : .dark)
        .onDisappear { model.cancel() }
        .sheet(isPresented: $model.isBrowsing) { directoryPicker }
        .confirmationDialog("Remove saved project?", isPresented: Binding(
            get: { projectToDelete != nil },
            set: { if !$0 { projectToDelete = nil } }
        ), titleVisibility: .visible) {
            if let project = projectToDelete {
                Button("Remove \(project.name)", role: .destructive) { model.store.delete(project) }
            }
        } message: {
            Text("The folder and its files will remain untouched.")
        }
    }

    private var directoryPicker: some View {
        WorkspaceBrowserSheet(
            title: model.selectedProfileID == nil ? "Choose Local Folder" : "Choose Remote Folder",
            directory: model.browsedDirectory,
            entries: model.folders,
            isBusy: model.isBusy,
            error: model.error,
            showsHiddenFiles: $model.showsHiddenFiles,
            pendingPath: model.directoryPath,
            onBrowse: { model.browse(path: $0) },
            onCancel: { model.cancel(); model.isBrowsing = false },
            confirmTitle: "Use This Folder",
            canConfirm: !model.isBusy && model.browsedDirectory != nil && model.error == nil,
            onConfirm: model.useBrowsedFolder
        )
    }
}

#Preview {
    ProjectCreationSheet(windowSession: WindowSession(), profileStore: SSHProfileStore())
}
