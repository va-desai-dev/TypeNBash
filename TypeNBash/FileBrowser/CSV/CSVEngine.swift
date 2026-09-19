import SwiftUI
import UniformTypeIdentifiers
import AppKit

struct CSVEditorView: View {
    @State private var storage = CSVStorage()
    @State private var session = EditorSession()
    @State private var refreshTrigger = false

    @State private var isImporting = false
    @State private var isExporting = false
    @State private var documentText = ""
    @State private var currentFileURL: URL? = nil
    @State private var isLoading = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button(action: { isImporting = true }) {
                    Label("Open CSV File", systemImage: "doc.badge.gearshape")
                }

                Button(action: prepareAndExport) {
                    Label("Export/Save", systemImage: "square.and.arrow.up")
                }
                .disabled(storage.columns.isEmpty)

                if let fileURL = currentFileURL {
                    Text(fileURL.lastPathComponent)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .truncationMode(.middle)
                }
                Spacer()

                if !storage.columns.isEmpty {
                    Button(action: appendNewRow) {
                        Label("Add Record Row", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            if isLoading {
                Spacer()
                ProgressView("Analyzing local data lines...")
                Spacer()
            } else if storage.columns.isEmpty {
                Spacer()
                ContentUnavailableView("No Document Mounted",
                                       systemImage: "tablecells",
                                       description: Text("Open a standard CSV layout locally to initialize hardware structural arrays."))
                Spacer()
            } else {
                FastCSVTableView(storage: storage, refreshTrigger: $refreshTrigger, session: session)
                    .background(Color(NSColor.controlBackgroundColor))
            }
        }
        .frame(minWidth: 800, minHeight: 500)
        .fileImporter(
            isPresented: $isImporting,
            allowedContentTypes: [UTType.commaSeparatedText],
            allowsMultipleSelection: false
        ) { result in
            processImport(result: result)
        }
        .fileExporter(
            isPresented: $isExporting,
            document: CSVTextDocument(text: documentText),
            contentType: .commaSeparatedText,
            defaultFilename: currentFileURL?.deletingPathExtension().lastPathComponent ?? "ExportedData"
        ) { result in
            if case .success(let url) = result {
                self.currentFileURL = url
            }
        }
    }

    private func appendNewRow() {
        let blankCells = Array(repeating: "", count: storage.columns.count)
        storage.rows.append(blankCells)
        refreshTrigger.toggle()
    }

    private func processImport(result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let selectedURL = urls.first else { return }
        isLoading = true
        currentFileURL = selectedURL

        DispatchQueue.global(qos: .userInitiated).async {
            guard selectedURL.startAccessingSecurityScopedResource() else {
                DispatchQueue.main.async { self.isLoading = false }
                return
            }
            defer { selectedURL.stopAccessingSecurityScopedResource() }

            do {
                let fileContents = try String(contentsOf: selectedURL, encoding: .utf8)

                // Parse directly into unobserved memory storage heap
                CSVEngine.parse(fileContents, into: storage)

                DispatchQueue.main.async {
                    self.refreshTrigger.toggle()
                    self.isLoading = false
                }
            } catch {
                DispatchQueue.main.async {
                    self.isLoading = false
                }
            }
        }
    }

    private func prepareAndExport() {
        session.csvGrid?.commitEditingIfNeeded()
        documentText = CSVEngine.generate(from: storage)
        isExporting = true
    }
}

