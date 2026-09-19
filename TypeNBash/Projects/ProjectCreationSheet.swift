import SwiftUI

struct ProjectCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectPickerModel
    @State private var browsePath = ""
    @State private var projectToDelete: Project?

    private let onOpen: () -> Void
    private let isEmbedded: Bool
    private let onCancel: (() -> Void)?

    init(windowSession: WindowSession, profileStore: SSHProfileStore,
         store: ProjectStore? = nil, onOpen: @escaping () -> Void = {},
         isEmbedded: Bool = false, onCancel: (() -> Void)? = nil) {
        let model = ProjectPickerModel(session: windowSession, profiles: profileStore, store: store)
        model.setupMode = isEmbedded ? .newFolder : .openFolder
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
        .background(isEmbedded ? Color(nsColor: .windowBackgroundColor) : Color.card)
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
        VStack(alignment: .leading, spacing: 12) {
            Text(model.selectedProfileID == nil ? "Choose Local Folder" : "Choose Remote Folder")
                .font(.headline)
            HStack {
                Button("Home", systemImage: "house") { model.browse() }
                Button("Up", systemImage: "arrow.up") {
                    if let directory = model.browsedDirectory {
                        model.browse(path: directory.deletingLastPathComponent().path)
                    }
                }
                .disabled(model.browsedDirectory == nil || model.browsedDirectory?.path == "/")
                Spacer()
                Toggle("Hidden folders", isOn: $model.showsHiddenFiles)
                    .onChange(of: model.showsHiddenFiles) {
                        model.browse(path: model.browsedDirectory?.path)
                    }
            }
            .disabled(model.isBusy)
            HStack {
                TextField("Folder path, such as ~/projects", text: $browsePath)
                    .onSubmit { model.browse(path: browsePath) }
                Button("Go") { model.browse(path: browsePath) }
            }
            .disabled(model.isBusy)
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(.red).textSelection(.enabled)
            }
            List(model.folders) { folder in
                Button {
                    model.browse(path: folder.url.path)
                } label: {
                    Label(folder.url.lastPathComponent, systemImage: "folder")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .disabled(model.isBusy)
            .overlay {
                if model.isBusy {
                    ProgressView()
                } else if model.folders.isEmpty, model.error == nil {
                    Text("No subfolders").foregroundStyle(.secondary)
                }
            }
            HStack {
                Button("Cancel", role: .cancel) { model.cancel(); model.isBrowsing = false }
                Spacer()
                Button("Use This Folder") { model.useBrowsedFolder() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isBusy || model.browsedDirectory == nil || model.error != nil)
            }
        }
        .padding(16)
        .frame(width: 560, height: 440)
        .background(isEmbedded ? Color(nsColor: .windowBackgroundColor) : Color.card)
        .interactiveDismissDisabled(model.isBusy)
        .onAppear { browsePath = model.browsedDirectory?.path(percentEncoded: false) ?? model.directoryPath }
        .onChange(of: model.browsedDirectory) {
            browsePath = model.browsedDirectory?.path(percentEncoded: false) ?? ""
        }
    }
}

#Preview {
    ProjectCreationSheet(windowSession: WindowSession(), profileStore: SSHProfileStore())
}
