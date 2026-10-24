import Foundation
import Observation

/// Owns one project's notebook: its steps, the tables they read, and the
/// results they have produced so far.
///
/// Steps are document content and live in the sidecar. Results are session
/// values and do not, because a number saved next to data that has since moved
/// on is worse than no number at all.
@Observable
final class NotebookModel {

    /// The table the editor was showing when the notebook was opened.
    ///
    /// Opening the notebook replaces the editor pane, which unmounts the grid,
    /// so there is no live grid to read once this view is on screen. Capturing
    /// on the way in is also the honest model for analysis: a step runs against
    /// data that was taken at a known moment, uncommitted cell edits included,
    /// rather than against whatever the table happens to say mid-scroll.
    struct OpenTableCapture: Sendable {
        /// Project-relative path of the captured file, when it has one.
        let path: String?
        let allRows: CSVAnalysisSnapshot
        let visibleRows: CSVAnalysisSnapshot
        let capturedAt: Date

        func snapshot(for scope: CSVAnalysisSnapshot.Scope) -> CSVAnalysisSnapshot {
            scope == .allRows ? self.allRows : self.visibleRows
        }
    }

    static let datasetByteLimit = 32 * 1_024 * 1_024

    private(set) var steps: [AnalysisStep] = []
    private(set) var results: [UUID: AnalysisResult] = [:]
    private(set) var failures: [UUID: String] = [:]
    private(set) var runningSteps: Set<UUID> = []
    private(set) var capture: OpenTableCapture?
    /// Project-relative paths of the CSV files in the project root.
    private(set) var availableDatasets: [String] = []
    private(set) var hasUnsavedChanges = false
    private(set) var isLoaded = false
    var errorMessage: String?

    /// Cell text that counts as missing rather than unusable, for every step.
    ///
    /// Every result in the notebook was computed under some vocabulary, so
    /// changing it invalidates all of them at once. Rather than leave stale
    /// numbers on screen labelled as current, the steps that have already run
    /// are run again.
    var missingCodes: [String] = ["NA"] {
        didSet {
            guard self.missingCodes != oldValue else { return }
            self.hasUnsavedChanges = true
            self.rerun?.cancel()
            self.rerun = Task { await self.rerunComputedSteps() }
        }
    }

    private let session: WindowSession
    private let editor: EditorSession
    private var headerCache: [String: [String]] = [:]
    private var levelCache: [String: [String]] = [:]
    @ObservationIgnored private var rerun: Task<Void, Never>?

    init(session: WindowSession, editor: EditorSession) {
        self.session = session
        self.editor = editor
    }

    // MARK: Input

    /// Takes the editor's table before the notebook replaces that pane. Called
    /// by the toolbar action, not by a view's lifecycle, so the capture happens
    /// while the grid is still mounted.
    func captureOpenTable() {
        guard self.editor.csvGrid != nil else { self.capture = nil; return }
        do {
            self.capture = OpenTableCapture(
                path: self.relativePath(of: self.session.fileBrowser.selectedFile),
                allRows: try self.editor.csvAnalysisSnapshot(scope: .allRows),
                visibleRows: try self.editor.csvAnalysisSnapshot(scope: .visibleRows),
                capturedAt: Date()
            )
        } catch {
            self.capture = nil
        }
    }

    /// The table a step reads. The captured grid wins over the file on disk for
    /// the same path, because that is where unsaved cell edits are.
    private func snapshot(for step: AnalysisStep) async throws -> CSVAnalysisSnapshot {
        if step.dataset.isEmpty {
            guard let capture else {
                throw CSVAnalysisError.datasetUnavailable("No CSV table was open when this notebook was opened. Open one, close the notebook and reopen it, or point this step at a file in the project.")
            }
            return capture.snapshot(for: step.scope)
        }
        if let capture, capture.path == step.dataset {
            return capture.snapshot(for: step.scope)
        }
        return try await self.readDataset(step.dataset)
    }

    private func readDataset(_ path: String) async throws -> CSVAnalysisSnapshot {
        let url = self.session.rootDirectory.appending(path: path)
        let limit = Self.datasetByteLimit
        let data = try await self.session.fileSystem.readFile(at: url, maximumByteCount: limit + 1)
        guard data.count <= limit else {
            throw CSVAnalysisError.datasetUnavailable("“\(path)” is larger than the \(limit / 1_048_576) MB analysis limit.")
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw CSVAnalysisError.datasetUnavailable("“\(path)” is not UTF-8 text.")
        }
        let table = await Task.detached(priority: .userInitiated) { CSVEngine.parse(text) }.value
        guard !table.isEmpty else {
            throw CSVAnalysisError.datasetUnavailable("“\(path)” has no header row to read.")
        }
        return CSVAnalysisSnapshot(table: table, sourceRows: Array(table.rows.indices), columnTypes: [:])
    }

    /// Column headers for the dataset picker, cached per path for the session.
    func headers(for dataset: String) async -> [String] {
        if dataset.isEmpty { return self.capture?.allRows.table.columns ?? [] }
        if let cached = self.headerCache[dataset] { return cached }
        guard let snapshot = try? await self.snapshot(for: AnalysisStep(dataset: dataset, operation: .describe(columns: []))) else {
            return []
        }
        self.headerCache[dataset] = snapshot.table.columns
        return snapshot.table.columns
    }

    /// The distinct values of a column, for choosing a baseline level.
    ///
    /// Capped at the point where a column is plainly an identifier rather than a
    /// factor, so the composer never tries to list ten thousand of them.
    func levels(for dataset: String, column: Int) async -> [String] {
        let key = "\(dataset)#\(column)"
        if let cached = self.levelCache[key] { return cached }
        guard let snapshot = try? await self.snapshot(
            for: AnalysisStep(dataset: dataset, operation: .describe(columns: []))),
              let values = try? snapshot.textColumn(at: column, missingCodes: Set(self.missingCodes))
        else { return [] }
        let levels = Set(values.values.compactMap { $0 })
        guard levels.count <= 200 else { return [] }
        let sorted = levels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        self.levelCache[key] = sorted
        return sorted
    }

    /// The grid's declared variable types, used only to preselect what the
    /// composer offers. They describe intent and never coerce a column.
    func hints(for dataset: String) -> [Int: CSVArrangement.VariableFlag] {
        guard let capture, dataset.isEmpty || capture.path == dataset else { return [:] }
        return capture.allRows.columnTypes
    }

    /// The captured table's own path, so a new step can be pinned to the file
    /// instead of to “whatever was open”.
    var captureLabel: String? {
        guard let capture else { return nil }
        let name = capture.path ?? "Untitled table"
        return "\(name) — \(capture.allRows.table.rows.count) rows, \(capture.allRows.table.columns.count) columns"
    }

    /// Whether the editor holds cell edits made after the capture was taken.
    var captureMayBeStale: Bool {
        self.capture != nil && self.editor.hasPendingCSVEdit
    }

    // MARK: Steps

    func add(_ step: AnalysisStep) {
        self.steps.append(step)
        self.hasUnsavedChanges = true
        Task { await self.run(step) }
    }

    func remove(_ id: UUID) {
        self.steps.removeAll { $0.id == id }
        self.results[id] = nil
        self.failures[id] = nil
        self.hasUnsavedChanges = true
    }

    // MARK: Running

    func run(_ step: AnalysisStep) async {
        self.runningSteps.insert(step.id)
        defer { self.runningSteps.remove(step.id) }
        self.failures[step.id] = nil
        do {
            let snapshot = try await self.snapshot(for: step)
            let codes = Set(self.missingCodes)
            let result = try await Task.detached(priority: .userInitiated) {
                try AnalysisKernel.run(step, on: snapshot, missingCodes: codes)
            }.value
            self.results[step.id] = result
        } catch is CancellationError {
        } catch {
            self.results[step.id] = nil
            self.failures[step.id] = error.localizedDescription
        }
    }

    func runAll() async {
        for step in self.steps { await self.run(step) }
    }

    /// Steps that have produced a result or an error already. A step never run
    /// stays that way — recomputing the vocabulary is not a reason to start it.
    private func rerunComputedSteps() async {
        for step in self.steps where self.results[step.id] != nil || self.failures[step.id] != nil {
            if Task.isCancelled { return }
            await self.run(step)
        }
    }

    // MARK: Persistence

    func load() async {
        defer { self.isLoaded = true }
        do {
            self.availableDatasets = try await self.projectDatasets()
            guard let file = try await AnalysisNotebookFile.load(in: self.session.rootDirectory,
                                                                fileSystem: self.session.fileSystem) else { return }
            self.steps = file.steps
            self.missingCodes = file.missingCodes
            self.hasUnsavedChanges = false
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    func save() async {
        do {
            let file = AnalysisNotebookFile(missingCodes: self.missingCodes, steps: self.steps)
            try await file.save(in: self.session.rootDirectory, fileSystem: self.session.fileSystem)
            self.hasUnsavedChanges = false
        } catch {
            self.errorMessage = error.localizedDescription
        }
    }

    private func projectDatasets() async throws -> [String] {
        let entries = try await self.session.fileSystem.contentsOfDirectory(at: self.session.rootDirectory,
                                                                           includingHiddenFiles: false)
        return entries
            .filter { !$0.isDirectory && $0.url.pathExtension.lowercased() == "csv" }
            .map(\.url.lastPathComponent)
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Writes the notebook's steps out as an R script and returns its URL.
    ///
    /// The script goes in the project root rather than the output folder: it is
    /// something to keep and edit, not a generated artifact. A name already in
    /// use is not overwritten — "new" means new.
    /// A notebook with no steps still writes a script: it loads the captured
    /// table and stops there. Wanting to write R against a CSV is a reason to
    /// ask for this, and requiring steps first would be backwards.
    func createRScript() async -> URL? {
        guard !self.steps.isEmpty || self.capture != nil else {
            self.errorMessage = "Open a CSV or add a step before writing a script."
            return nil
        }
        do {
            let root = self.session.rootDirectory
            let existing = Set(try await self.session.fileSystem
                .contentsOfDirectory(at: root, includingHiddenFiles: true)
                .map(\.url.lastPathComponent))

            // Each distinct dataset becomes one data frame. A step reading the
            // captured table points at the file it came from, so the script
            // reads the same data the pane did without a copy beside it.
            var sources: [String: NotebookScript.Source] = [:]
            var frame = 1
            let datasets = self.steps.isEmpty ? [""] : Set(self.steps.map(\.dataset)).sorted()
            for dataset in datasets {
                let path: String?
                if dataset.isEmpty {
                    path = self.capture?.path
                } else {
                    path = dataset
                }
                guard let path else {
                    self.errorMessage = "The captured table has not been saved to the project, so a script has no file to read. Save it first."
                    return nil
                }
                sources[dataset] = NotebookScript.Source(frame: "data\(frame)", path: path)
                frame += 1
            }

            var name = "analysis.R"
            var attempt = 2
            while existing.contains(name) {
                name = "analysis-\(attempt).R"
                attempt += 1
            }
            let script = NotebookScript.r(steps: self.steps, missingCodes: self.missingCodes,
                                          sources: sources)
            let url = root.appending(path: name)
            try await self.session.fileSystem.createFile(Data(script.utf8), at: url)
            self.availableDatasets = try await self.projectDatasets()
            return url
        } catch {
            self.errorMessage = error.localizedDescription
            return nil
        }
    }

    /// Writes the results as they stand to the project's output directory.
    @discardableResult
    func export() async -> URL? {
        do {
            let directory = try await self.session.prepareProjectOutputDirectory()
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let url = directory.appending(path: "notebook-\(stamp).md")
            let report = NotebookReport.markdown(steps: self.steps, results: self.results,
                                                 failures: self.failures, missingCodes: self.missingCodes)
            try await self.session.fileSystem.writeFile(Data(report.utf8), to: url)
            return url
        } catch {
            self.errorMessage = error.localizedDescription
            return nil
        }
    }

    private func relativePath(of url: URL?) -> String? {
        guard let url else { return nil }
        let root = self.session.rootDirectory.standardizedFileURL.pathComponents
        let file = url.standardizedFileURL.pathComponents
        guard file.count > root.count, file.starts(with: root) else { return nil }
        return file.dropFirst(root.count).joined(separator: "/")
    }
}
