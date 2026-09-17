import SwiftUI

struct ProjectCreationSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var model: ProjectPickerModel
    @State private var browsePath = ""
    @State private var projectToDelete: Project?

    init(windowSession: WindowSession, profileStore: SSHProfileStore) {
        _model = State(initialValue: ProjectPickerModel(session: windowSession, profiles: profileStore))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "folder")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Open a Project").font(.headline)
                    Text("Choose a workspace on this Mac or an SSH host.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)
            Divider()
            Form {
                if !model.store.projects.isEmpty {
                    Section("Saved projects") {
                        ForEach(model.store.projects) { project in
                            HStack {
                                Button {
                                    model.openSaved(project) { dismiss() }
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
                    TextField("Name (defaults to folder name)", text: $model.name)
                        .disabled(model.isBusy)
                    HStack {
                        TextField("Project directory", text: $model.directoryPath)
                        Button("Choose Folder", systemImage: "folder") { model.chooseFolder() }
                    }
                    .disabled(model.isBusy)
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
                Button("Cancel", role: .cancel) { model.cancel(); dismiss() }
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
                Button("Open Project") { model.saveAndOpen { dismiss() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canOpen)
            }
            .padding(16)
        }
        .frame(width: 560, height: 580)
        .background(Color.card)
        .foregroundStyle(Color.foreground)
        .tint(Color.accentColor)
        .preferredColorScheme(.dark)
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
        .background(Color.card)
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
