import SwiftUI

/// The notebook pane. Presentation only: it builds `AnalysisStep` values and
/// renders `AnalysisResult` values, and never computes a statistic itself.
struct NotebookView: View {
    @Bindable var model: NotebookModel
    @State private var composing: AnalysisOperationKind?
    var showsFooter = true
    /// Hands a freshly written script to whoever owns the editor, since the
    /// notebook replaced that pane to be on screen at all.
    var onOpenScript: ((URL) -> Void)?

    var body: some View {
        Group {
            if model.steps.isEmpty {
                ContentUnavailableView {
                    Label("No Analysis Steps", systemImage: "function")
                } description: {
                    Text("Add a step to summarize, tabulate or correlate the captured table. Steps are saved with the project; results are recomputed.")
                } actions: {
                    self.addMenu
                }
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(model.steps) { step in
                            NotebookStepCard(model: model, step: step)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .safeAreaInset(edge: .top) {
            VStack(spacing: 0) {
                self.header
                Divider()
            }
            .background(Color.card)
        }
        .background(Color.card)
        .task { if !model.isLoaded { await model.load() } }
        .sheet(item: $composing) { kind in
            NotebookStepComposer(model: model, kind: kind) { step in
                model.add(step)
                composing = nil
            }
        }
        .alert("Notebook", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { }
        } message: { Text(model.errorMessage ?? "") }
    }

    private var header: some View {
        HStack(spacing: 10) {
            if model.hasUnsavedChanges {
                Circle().fill(Color.orange).frame(width: 6, height: 6)
                    .help("Unsaved notebook changes")
            }
            Text("Notebook").font(.headline)
            if let label = model.captureLabel {
                Text(label).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            } else {
                Text("No table captured").foregroundStyle(Color.orange)
                    .help("Open a CSV in the editor, then reopen the notebook to capture it.")
            }
            Spacer()
            self.addMenu
            // Each of these says why it is unavailable. A greyed button with no
            // reason sends people looking for a cause that isn't there.
            Button("Run All") { Task { await model.runAll() } }
                .disabled(model.steps.isEmpty || !model.runningSteps.isEmpty)
                .help(model.steps.isEmpty
                      ? "Add a step to run"
                      : "Recompute every step against the captured table")
            Button("New R Notebook") {
                Task {
                    if let url = await model.createRScript() { onOpenScript?(url) }
                }
            }
            .disabled(model.steps.isEmpty && model.capture == nil)
            .help(model.steps.isEmpty
                  ? "Write an R script that loads this table, and open it. Send a cell to the console with ⌃⏎."
                  : "Write these steps out as an R script and open it. Send a cell to the console with ⌃⏎.")
            Button("Export") { Task { await model.export() } }
                .disabled(model.results.isEmpty)
                .help(model.results.isEmpty
                      ? "Run a step to have results to export"
                      : "Write these results to the project's output folder")
            Button("Save") { Task { await model.save() } }
                .buttonStyle(.bordered)
                .disabled(!model.hasUnsavedChanges)
                .help(model.hasUnsavedChanges
                      ? "Save the steps to \(AnalysisNotebookFile.filename)"
                      : "No unsaved changes")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
    }

    private var addMenu: some View {
        Menu("Add Step") {
            ForEach(AnalysisOperationKind.Family.allCases) { family in
                Section(family.rawValue) {
                    ForEach(AnalysisOperationKind.allCases.filter { $0.family == family }) { kind in
                        Button(kind.title) { composing = kind }
                    }
                }
            }
        }
        .fixedSize()
        .disabled(model.capture == nil && model.availableDatasets.isEmpty)
    }
}

/// The operations the composer can build, grouped the way a statistics package
/// groups them. Kept apart from `AnalysisOperation` because that one carries its
/// columns and this one is only a menu choice.
///
/// Each entry is one named test. Nothing here inspects the data and decides on
/// the user's behalf whether they meant a t-test, an ANOVA or a test of
/// independence — choosing that is the analysis.
enum AnalysisOperationKind: String, CaseIterable, Identifiable {
    case describe, frequency, crossTabulation
    case oneSampleT, independentT, pairedT, oneWayANOVA
    case correlation
    case linearRegression
    case chiSquareIndependence

    var id: String { self.rawValue }

    enum Family: String, CaseIterable, Identifiable {
        case describe = "Descriptives"
        case compareMeans = "Compare Means"
        case correlate = "Correlate"
        case regression = "Regression"
        case categorical = "Categorical"

        var id: String { self.rawValue }
    }

    var family: Family {
        switch self {
            case .describe, .frequency, .crossTabulation: .describe
            case .oneSampleT, .independentT, .pairedT, .oneWayANOVA: .compareMeans
            case .correlation: .correlate
            case .linearRegression: .regression
            case .chiSquareIndependence: .categorical
        }
    }

    var title: String {
        switch self {
            case .describe: "Descriptive Statistics…"
            case .frequency: "Frequency Table…"
            case .crossTabulation: "Cross-Tabulation…"
            case .oneSampleT: "One-Sample T Test…"
            case .independentT: "Independent-Samples T Test…"
            case .pairedT: "Paired-Samples T Test…"
            case .oneWayANOVA: "One-Way ANOVA…"
            case .correlation: "Correlation Matrix…"
            case .linearRegression: "Linear Regression…"
            case .chiSquareIndependence: "Chi-Square Test of Independence…"
        }
    }

    var allowsManyColumns: Bool { self == .describe || self == .correlation }

    /// One outcome plus a list of predictors, which is neither of the other two
    /// shapes the composer knows.
    var picksPredictors: Bool { self == .linearRegression }

    var primaryLabel: String {
        switch self {
            case .describe, .correlation: "Variables"
            case .frequency, .oneSampleT: "Variable"
            case .crossTabulation, .chiSquareIndependence: "Rows"
            case .independentT, .oneWayANOVA, .linearRegression: "Outcome"
            case .pairedT: "First"
        }
    }

    /// Nil for the operations that read a single column or a free set of them.
    var secondaryLabel: String? {
        switch self {
            case .crossTabulation, .chiSquareIndependence: "Columns"
            case .independentT: "Groups"
            case .oneWayANOVA: "Factor"
            case .pairedT: "Second"
            case .describe, .frequency, .correlation, .oneSampleT, .linearRegression: nil
        }
    }

    var needsTestValue: Bool { self == .oneSampleT }
}

// MARK: - One step and its result

private struct NotebookStepCard: View {
    @Bindable var model: NotebookModel
    let step: AnalysisStep

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(step.title).font(.headline)
                Spacer()
                if model.runningSteps.contains(step.id) {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Run") { Task { await model.run(step) } }
                        .buttonStyle(.borderless)
                }
                Button("Remove", systemImage: "trash") { model.remove(step.id) }
                    .buttonStyle(.borderless)
                    .labelStyle(.iconOnly)
            }
            if let failure = model.failures[step.id] {
                Label(failure, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.orange)
                    .font(.callout)
            } else if let result = model.results[step.id] {
                self.summary(result.input)
                ForEach(result.notes, id: \.self) { note in
                    Text(note).font(.callout).foregroundStyle(.secondary)
                }
                ForEach(result.tables) { table in
                    AnalysisTableView(table: table)
                }
            } else {
                Text("Not run yet.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.foreground.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    /// What the numbers were computed from, so a result stays readable after the
    /// table underneath it has moved on.
    private func summary(_ input: AnalysisInputSummary) -> some View {
        Text("\(input.datasetLabel) · \(input.scope.label) · \(input.rowCount) rows · \(step.missing.rawValue) · capture \(input.fingerprint) at \(input.capturedAt.formatted(date: .omitted, time: .standard))")
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

/// A result table. Long tables are cut off on screen and complete in the export,
/// because 500 rows of frequencies is a file, not a pane.
private struct AnalysisTableView: View {
    static let displayLimit = 200
    let table: AnalysisResultTable

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let caption = table.caption {
                Text(caption).font(.caption).foregroundStyle(.secondary)
            }
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow {
                        ForEach(Array(table.columns.enumerated()), id: \.offset) { _, column in
                            Text(column).bold()
                        }
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                    ForEach(Array(table.rows.prefix(Self.displayLimit).enumerated()), id: \.offset) { _, row in
                        GridRow {
                            ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                                Text(NotebookReport.text(cell))
                                    .monospacedDigit()
                                    .foregroundStyle(cell == .missing ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                            }
                        }
                    }
                }
                .font(.callout)
                .padding(.vertical, 4)
            }
            if table.rows.count > Self.displayLimit {
                Text("Showing \(Self.displayLimit) of \(table.rows.count) rows — export for the rest.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct NoteBookFooter: View {
    @Bindable var model: NotebookModel
    var showsSeparator = true
    @State private var missingCodesField = ""
    @FocusState private var isEditingCodes: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showsSeparator { Divider() }
            HStack(spacing: 8) {
                Text("Missing Data Codes")
                    .foregroundStyle(.secondary)
                TextField("NA", text: $missingCodesField)
                    .textFieldStyle(.plain)
                    .frame(maxWidth: 260)
                    .focused($isEditingCodes)
                    .onSubmit { self.commitCodes() }
                    // Clicking away is how a field in a status bar is usually
                    // left, so losing focus commits rather than discarding.
                    .onChange(of: isEditingCodes) { _, editing in if !editing { self.commitCodes() } }
                    .help("Cell text that counts as missing rather than unusable. Blanks always count. N/A is not included by default, because it usually marks a meaningful skip rather than absent data. Changing this re-runs the steps that have already run.")
                if model.captureMayBeStale {
                    Label("The table has been edited since this capture", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Color.orange)
                        .help("Close and reopen the notebook to capture the edited table.")
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .foregroundStyle(Color.foreground)
        }
        .background(Color.card)
        .onAppear { missingCodesField = model.missingCodes.joined(separator: ", ") }
    }

    private func commitCodes() {
        model.missingCodes = missingCodesField
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
// MARK: - Composing a step

private struct NotebookStepComposer: View {
    @Bindable var model: NotebookModel
    let kind: AnalysisOperationKind
    let onAdd: (AnalysisStep) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var dataset = ""
    @State private var scope = CSVAnalysisSnapshot.Scope.allRows
    @State private var missing = MissingPolicy.pairwise
    @State private var method = CorrelationMethod.pearson
    @State private var adjustment = PValueAdjustment.holm
    @State private var variance = VarianceAssumption.welch
    @State private var testValue = "0"
    @State private var headers: [String] = []
    /// Predictors the user declared categorical, and the baseline each is coded
    /// against. Kept beside `selection` because they only apply to regression.
    @State private var categorical: Set<Int> = []
    @State private var baselines: [Int: String] = [:]
    @State private var levels: [Int: [String]] = [:]
    @State private var selection: Set<Int> = []
    @State private var primary = 0
    @State private var secondary = 1

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(kind.title.replacingOccurrences(of: "…", with: "")).font(.title3).bold()

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
                GridRow {
                    Text("Table")
                    Picker("Table", selection: $dataset) {
                        if model.capture != nil { Text("Captured open table").tag("") }
                        ForEach(model.availableDatasets, id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                }
                if dataset.isEmpty {
                    GridRow {
                        Text("Rows")
                        Picker("Rows", selection: $scope) {
                            ForEach(CSVAnalysisSnapshot.Scope.allCases) { Text($0.label).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .help("Filtered rows use the grid's sort and filters as they were when the notebook opened.")
                    }
                }
                GridRow {
                    Text("Missing")
                    Picker("Missing", selection: $missing) {
                        ForEach(MissingPolicy.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .labelsHidden()
                }
                if kind == .independentT {
                    GridRow {
                        Text("Variances")
                        Picker("Variances", selection: $variance) {
                            ForEach(VarianceAssumption.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                        .help("Welch does not assume the groups share a variance and is the safer default. Levene's test is reported either way.")
                    }
                }
                if kind.needsTestValue {
                    GridRow {
                        Text("Test value")
                        TextField("0", text: $testValue)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 120)
                            .help("The value the mean is compared against, H₀: μ = this.")
                    }
                }
                if kind == .correlation {
                    GridRow {
                        Text("Method")
                        Picker("Method", selection: $method) {
                            ForEach(CorrelationMethod.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .pickerStyle(.segmented)
                    }
                    GridRow {
                        Text("Adjust p")
                        Picker("Adjust p", selection: $adjustment) {
                            ForEach(PValueAdjustment.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .labelsHidden()
                        .help("Every pair of variables is a separate test. Holm controls the family-wise error rate; Benjamini–Hochberg controls the false discovery rate.")
                    }
                }
            }

            Divider()
            self.columnSelection

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Add Step") { onAdd(self.makeStep()) }
                    .buttonStyle(.borderedProminent)
                    .disabled(!self.isValid)
            }
        }
        .padding(18)
        .frame(width: 460)
        .background(Color.card)
        .task(id: dataset) {
            headers = await model.headers(for: dataset)
            selection = []
            primary = 0
            secondary = min(1, max(0, headers.count - 1))
            // The grid's declared types only preselect what is offered here.
            let hints = model.hints(for: dataset)
            categorical = Set(hints.filter { _, flag in
                flag == .factor || flag == .character || flag == .logical
            }.keys)
            baselines = [:]
            levels = [:]
        }
    }

    @ViewBuilder private var columnSelection: some View {
        if headers.isEmpty {
            Text("This table has no columns to analyze.").foregroundStyle(.secondary)
        } else if kind.picksPredictors {
            Picker(kind.primaryLabel, selection: $primary) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(self.label(index, header)).tag(index)
                }
            }
            Text("Predictors").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        self.predictorRow(index, header)
                    }
                }
            }
            .frame(maxHeight: 220)
        } else if kind.allowsManyColumns {
            Text(kind == .correlation ? "Variables (pick at least two)" : "Variables")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Toggle(self.label(index, header), isOn: Binding(
                            get: { selection.contains(index) },
                            set: { isOn in
                                if isOn { selection.insert(index) } else { selection.remove(index) }
                            }
                        ))
                    }
                }
            }
            .frame(maxHeight: 220)
        } else {
            Picker(kind.primaryLabel, selection: $primary) {
                ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                    Text(self.label(index, header)).tag(index)
                }
            }
            if let label = kind.secondaryLabel {
                Picker(label, selection: $secondary) {
                    ForEach(Array(headers.enumerated()), id: \.offset) { index, header in
                        Text(self.label(index, header)).tag(index)
                    }
                }
            }
        }
    }

    /// One predictor: whether it is in the model, whether it enters as a factor,
    /// and which of its levels the others are measured against.
    @ViewBuilder private func predictorRow(_ index: Int, _ header: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Toggle(self.label(index, header), isOn: Binding(
                    get: { selection.contains(index) },
                    set: { isOn in
                        if isOn { selection.insert(index) } else { selection.remove(index) }
                    }
                ))
                .disabled(index == primary)
                if selection.contains(index) {
                    Spacer()
                    Toggle("Categorical", isOn: Binding(
                        get: { categorical.contains(index) },
                        set: { isOn in
                            if isOn { categorical.insert(index) } else { categorical.remove(index) }
                            if isOn, levels[index] == nil { self.loadLevels(index) }
                        }
                    ))
                    .toggleStyle(.checkbox)
                    .help("Enter this column as a set of indicators rather than as a number.")
                }
            }
            if selection.contains(index), categorical.contains(index) {
                HStack(spacing: 6) {
                    Text("Baseline").font(.caption).foregroundStyle(.secondary)
                    Picker("Baseline", selection: Binding(
                        get: { baselines[index] ?? levels[index]?.first ?? "" },
                        set: { baselines[index] = $0 }
                    )) {
                        ForEach(levels[index] ?? [], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .disabled((levels[index] ?? []).isEmpty)
                    .help("Every coefficient for this variable is its difference from this level.")
                }
                .padding(.leading, 20)
            }
        }
    }

    private func loadLevels(_ index: Int) {
        Task {
            let found = await model.levels(for: dataset, column: index)
            levels[index] = found
            if baselines[index] == nil { baselines[index] = found.first }
        }
    }

    private func label(_ index: Int, _ header: String) -> String {
        header.isEmpty ? "Column \(index + 1)" : header
    }

    private func reference(_ index: Int) -> ColumnReference {
        ColumnReference(index: index, name: headers.indices.contains(index) ? headers[index] : "")
    }

    private var isValid: Bool {
        if headers.isEmpty { return false }
        switch kind {
            case .describe: return !selection.isEmpty
            case .correlation: return selection.count >= 2
            case .frequency: return true
            case .oneSampleT: return Double(testValue.trimmingCharacters(in: .whitespaces)) != nil
            case .linearRegression:
                return !selection.isEmpty && !selection.contains(primary)
                    && selection.filter { categorical.contains($0) }
                        .allSatisfy { !(levels[$0] ?? []).isEmpty }
            case .crossTabulation, .chiSquareIndependence, .independentT, .pairedT, .oneWayANOVA:
                return primary != secondary
        }
    }

    private func makeStep() -> AnalysisStep {
        let picked = selection.sorted().map(self.reference)
        let operation: AnalysisOperation = switch kind {
            case .describe: .describe(columns: picked)
            case .correlation: .correlation(columns: picked, method: method)
            case .frequency: .frequency(column: self.reference(primary))
            case .crossTabulation:
                .crossTabulation(rows: self.reference(primary), columns: self.reference(secondary))
            case .chiSquareIndependence:
                .chiSquareIndependence(rows: self.reference(primary), columns: self.reference(secondary))
            case .oneSampleT:
                .oneSampleT(column: self.reference(primary),
                            testValue: Double(testValue.trimmingCharacters(in: .whitespaces)) ?? 0)
            case .independentT:
                .independentT(outcome: self.reference(primary), group: self.reference(secondary),
                              variance: variance)
            case .pairedT: .pairedT(first: self.reference(primary), second: self.reference(secondary))
            case .oneWayANOVA:
                .oneWayANOVA(outcome: self.reference(primary), factor: self.reference(secondary))
            case .linearRegression:
                .linearRegression(outcome: self.reference(primary),
                                  predictors: selection.sorted().map { index in
                                      RegressionPredictor(
                                          column: self.reference(index),
                                          isCategorical: categorical.contains(index),
                                          referenceLevel: categorical.contains(index) ? baselines[index] : nil)
                                  })
        }
        return AnalysisStep(dataset: dataset, scope: dataset.isEmpty ? scope : .allRows,
                            missing: missing, adjustment: adjustment, operation: operation)
    }
}
