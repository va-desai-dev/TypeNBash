//
//  BibFilePickerSheet.swift
//  TypeNBash
//
//  Created by Vedant A. Desai on 10/24/26.
//

import SwiftUI
import BibTeXViewer

/// The citations tab's "Choose or Create…" sheet.
struct BibFilePickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let library: BibLibrary
    @State private var model: BibFilePickerModel

    init(library: BibLibrary, fileSystem: any WorkspaceFileSystem) {
        self.library = library
        _model = State(initialValue: BibFilePickerModel(fileSystem: fileSystem))
    }

    var body: some View {
        WorkspaceBrowserSheet(
            title: "Choose Bibliography",
            directory: model.directory,
            entries: model.entries,
            isBusy: model.isBusy,
            error: model.error,
            showsHiddenFiles: $model.showsHiddenFiles,
            emptyText: "No folders or .bib files",
            selectedFile: model.selectedFile,
            onSelectFile: { model.selectedFile = $0 },
            onBrowse: { model.browse(path: $0) },
            onCancel: { model.cancel(); dismiss() },
            confirmTitle: "Use \(model.selectedFile?.lastPathComponent ?? "File")",
            canConfirm: !model.isBusy && model.selectedFile != nil,
            onConfirm: { use(model.selectedFile) }
        ) {
            HStack {
                TextField("New bibliography, such as references.bib", text: $model.newFileName)
                    .onSubmit(create)
                Button("Create Here", systemImage: "doc.badge.plus", action: create)
                    .disabled(model.isBusy || model.directory == nil
                              || model.newFileName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            // Open where the current .bib lives, or at the project root.
            model.selectedFile = library.fileURL
            let start = library.fileURL?.deletingLastPathComponent() ?? library.projectRoot
            model.browse(path: start.path)
        }
    }

    private func create() {
        model.createFile { url in use(url) }
    }

    private func use(_ url: URL?) {
        guard let url else { return }
        library.select(url)
        library.refreshAvailableFiles()
        dismiss()
    }
}
