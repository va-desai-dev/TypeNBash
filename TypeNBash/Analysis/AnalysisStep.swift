import Foundation

/// A notebook step as data rather than code.
///
/// The analysis layer rests on this one decision: a step *describes* a
/// calculation instead of performing one. The same value serializes into the
/// project sidecar, replays against a later version of a table, and — once a
/// Python/R extension exists — can be emitted as a script instead of being
/// handed to `AnalysisKernel`. Views build and edit these; nothing else.
nonisolated struct AnalysisStep: Identifiable, Hashable, Codable, Sendable {
    var id = UUID()
    /// Project-relative POSIX path of the table to read. Empty means the table
    /// open in the editor, including cell edits that have not been saved.
    var dataset = ""
    var scope = CSVAnalysisSnapshot.Scope.allRows
    var missing = MissingPolicy.pairwise
    /// Applies to steps that produce a family of tests at once, such as a
    /// correlation matrix. A single planned comparison is unaffected.
    var adjustment = PValueAdjustment.holm
    var operation: AnalysisOperation

    /// What the step reads, in the order the kernel reports drift.
    var columns: [ColumnReference] {
        switch self.operation {
        case .describe(let columns): columns
        case .frequency(let column): [column]
        case .crossTabulation(let rows, let columns): [rows, columns]
        case .chiSquareIndependence(let rows, let columns): [rows, columns]
        case .correlation(let columns, _): columns
        case .oneSampleT(let column, _): [column]
        case .independentT(let outcome, let group, _): [outcome, group]
        case .pairedT(let first, let second): [first, second]
        case .oneWayANOVA(let outcome, let factor): [outcome, factor]
        case .linearRegression(let outcome, let predictors): [outcome] + predictors.map(\.column)
        }
    }

    var title: String {
        let names = self.columns.map(\.label).joined(separator: ", ")
        return switch self.operation {
        case .describe: "Descriptives — \(names)"
        case .frequency: "Frequencies — \(names)"
        case .crossTabulation: "Cross-tabulation — \(names)"
        case .chiSquareIndependence(let rows, let columns):
            "Chi-square — \(rows.label) × \(columns.label)"
        case .correlation(_, let method): "\(method.rawValue) correlation — \(names)"
        case .oneSampleT(let column, let value): "One-sample t — \(column.label) vs \(value)"
        case .independentT(let outcome, let group, _):
            "Independent t — \(outcome.label) by \(group.label)"
        case .pairedT(let first, let second): "Paired t — \(first.label) vs \(second.label)"
        case .oneWayANOVA(let outcome, let factor):
            "One-way ANOVA — \(outcome.label) by \(factor.label)"
        case .linearRegression(let outcome, let predictors):
            "Linear regression — \(outcome.label) on \(predictors.map(\.column.label).joined(separator: " + "))"
        }
    }
}

/// A column addressed by position, because CSV headers can be blank or repeated.
///
/// The header text is carried alongside so a notebook written against one
/// version of a file can tell the difference between "column 3" and "Age". A
/// replay whose header no longer matches reports the drift rather than quietly
/// computing a different variable.
nonisolated struct ColumnReference: Hashable, Codable, Sendable {
    var index: Int
    var name: String

    var label: String { self.name.isEmpty ? "Column \(self.index + 1)" : self.name }
}

/// Each case is one analysis the user picked, never a family the kernel chooses
/// between. A cross-tabulation describes; a chi-square tests. Which of a t-test,
/// an ANOVA or a test of independence a question calls for is the analyst's
/// decision, and the level count of a grouping variable is not a proxy for it.
nonisolated enum AnalysisOperation: Hashable, Codable, Sendable {
    case describe(columns: [ColumnReference])
    case frequency(column: ColumnReference)
    case crossTabulation(rows: ColumnReference, columns: ColumnReference)
    case chiSquareIndependence(rows: ColumnReference, columns: ColumnReference)
    case correlation(columns: [ColumnReference], method: CorrelationMethod)
    case oneSampleT(column: ColumnReference, testValue: Double)
    case independentT(outcome: ColumnReference, group: ColumnReference, variance: VarianceAssumption)
    case pairedT(first: ColumnReference, second: ColumnReference)
    case oneWayANOVA(outcome: ColumnReference, factor: ColumnReference)
    case linearRegression(outcome: ColumnReference, predictors: [RegressionPredictor])
}

/// Whether a two-group comparison assumes the groups share a variance.
///
/// Welch is the default because it does not, and it costs almost nothing when
/// they do. The pooled test is kept because it is what a classical write-up
/// reports, and because it is the one that equals a linear model on a two-level
/// factor — which matters when regression lands.
/// A term on the right-hand side of a regression.
///
/// Whether a column enters as a number or as a set of indicators is the user's
/// declaration, not something inferred from its contents. A department coded
/// 1, 2, 3 is numeric to a parser and categorical to an analyst, and reading
/// those codes as a scale is a silent, plausible-looking mistake.
nonisolated struct RegressionPredictor: Hashable, Codable, Sendable {
    var column: ColumnReference
    var isCategorical = false
    /// The level held out as the baseline, against which the others are
    /// compared. Nil takes the first in sort order, and the result always names
    /// whichever it was, because every coefficient is read relative to it.
    var referenceLevel: String?
}

nonisolated enum VarianceAssumption: String, CaseIterable, Identifiable, Codable, Sendable {
    case welch = "Welch"
    case pooled = "Pooled"

    var id: String { self.rawValue }
}

/// Notebooks written before significance testing have no `adjustment` key, and
/// a notebook is a file someone may already have committed. Decoding fills in
/// the current default for anything absent rather than refusing to open.
nonisolated extension AnalysisStep {
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try values.decode(UUID.self, forKey: .id)
        self.dataset = try values.decodeIfPresent(String.self, forKey: .dataset) ?? ""
        self.scope = try values.decodeIfPresent(CSVAnalysisSnapshot.Scope.self, forKey: .scope) ?? .allRows
        self.missing = try values.decodeIfPresent(MissingPolicy.self, forKey: .missing) ?? .pairwise
        self.adjustment = try values.decodeIfPresent(PValueAdjustment.self, forKey: .adjustment) ?? .holm
        self.operation = try values.decode(AnalysisOperation.self, forKey: .operation)
    }
}

/// What to do about testing many hypotheses at once. A ten-variable correlation
/// matrix is forty-five simultaneous tests, and reporting those raw is how a
/// chance result gets written up as a finding.
nonisolated enum PValueAdjustment: String, CaseIterable, Identifiable, Codable, Sendable {
    case none = "None"
    case holm = "Holm"
    case benjaminiHochberg = "Benjamini–Hochberg"

    var id: String { self.rawValue }

    /// Holm controls the family-wise error rate and is uniformly more powerful
    /// than Bonferroni; Benjamini–Hochberg controls the false discovery rate
    /// instead, which is the looser and more usual choice when the matrix is
    /// exploratory. Both are monotone in the raw p-values, so the running
    /// max/min below is what keeps the adjusted values in the same order.
    func adjusted(_ values: [Double]) -> [Double] {
        let count = values.count
        guard self != .none, count > 1 else { return values }
        let ascending = values.indices.sorted { values[$0] < values[$1] }
        var result = [Double](repeating: .nan, count: count)
        switch self {
        case .none:
            return values
        case .holm:
            var running = 0.0
            for (rank, index) in ascending.enumerated() {
                running = max(running, Double(count - rank) * values[index])
                result[index] = min(1, running)
            }
        case .benjaminiHochberg:
            var running = 1.0
            for (rank, index) in ascending.enumerated().reversed() {
                running = min(running, Double(count) / Double(rank + 1) * values[index])
                result[index] = min(1, running)
            }
        }
        return result
    }
}

nonisolated enum CorrelationMethod: String, CaseIterable, Identifiable, Codable, Sendable {
    case pearson = "Pearson"
    case spearman = "Spearman"

    var id: String { self.rawValue }
}

/// How a step treats rows it cannot use. There is no default that is right for
/// every analysis, so it is recorded on the step and printed with the result.
nonisolated enum MissingPolicy: String, CaseIterable, Identifiable, Codable, Sendable {
    /// Each statistic uses the rows complete for the columns that statistic needs.
    case pairwise = "Pairwise"
    /// One row set for the whole step: rows complete across every column it reads.
    case listwise = "Listwise"
    /// Any missing or unusable value stops the step instead of dropping a row.
    case fail = "Fail on missing"

    var id: String { self.rawValue }
}

// MARK: - Results

/// A finished calculation, bound to the exact input it was computed from.
///
/// Results are session values, not document content: the sidecar stores steps
/// only, so a notebook in Git stays small and never carries numbers that no
/// longer match the data.
nonisolated struct AnalysisResult: Sendable {
    let stepID: UUID
    let title: String
    let tables: [AnalysisResultTable]
    /// What the kernel decided that the numbers alone don't show — dropped rows,
    /// header drift, a statistic that needed more data than the column had.
    let notes: [String]
    let input: AnalysisInputSummary
}

nonisolated struct AnalysisResultTable: Identifiable, Sendable {
    let id = UUID()
    var caption: String?
    var columns: [String]
    var rows: [[AnalysisCell]]
}

/// Cells carry their kind, not their formatting: a count and a coefficient print
/// differently, and that decision belongs to the view.
nonisolated enum AnalysisCell: Hashable, Sendable {
    case text(String)
    case count(Int)
    case number(Double)
    /// A p-value, which is printed to APA convention rather than as a plain
    /// number: three decimals with no leading zero, and `< .001` below that,
    /// because the exact value of a very small p is not what is being reported.
    case probability(Double)
    case missing
}

/// Identifies the table a result was computed from, so a stale result can be
/// labelled instead of silently redrawn beside data it never saw.
nonisolated struct AnalysisInputSummary: Hashable, Sendable {
    let dataset: String
    let scope: CSVAnalysisSnapshot.Scope
    let rowCount: Int
    let columnCount: Int
    /// Content hash of the exact table the kernel read.
    let fingerprint: String
    let capturedAt: Date

    var datasetLabel: String { self.dataset.isEmpty ? "Open table" : self.dataset }
}

// MARK: - Document

/// The portable notebook, stored beside `.typenbash.json` in the project root.
///
/// It holds steps and the project's missing-value vocabulary. Paths inside are
/// project-relative, so the file travels with a copied folder exactly like the
/// project definition does.
nonisolated struct AnalysisNotebookFile: Codable, Hashable, Sendable {
    static let filename = ".typenbash-notebook.json"
    static let byteLimit = 1_024 * 1_024
    static let stepLimit = 500

    var version = 1
    /// Cell text that counts as missing rather than unusable. CSV has no missing
    /// marker of its own, so the vocabulary is declared rather than guessed.
    ///
    /// `NA` is the default because it is the standard marker for an absent
    /// value, and blanks always count without being listed. `N/A` is
    /// deliberately *not* included: in survey and institutional research it
    /// usually marks a question meaningfully skipped — a qualitative fact about
    /// the respondent — rather than data that went missing. Folding it in by
    /// default would quietly inflate the missing count and shrink the n.
    var missingCodes: [String] = ["NA"]
    var steps: [AnalysisStep] = []

    func validate() throws {
        guard self.version == 1 else {
            throw CSVAnalysisError.unsupportedNotebook("Unsupported notebook format version \(self.version).")
        }
        guard self.steps.count <= Self.stepLimit else {
            throw CSVAnalysisError.unsupportedNotebook("A notebook holds at most \(Self.stepLimit) steps.")
        }
        for step in self.steps {
            guard step.columns.allSatisfy({ $0.index >= 0 }) else {
                throw CSVAnalysisError.unsupportedNotebook("A step refers to a negative column position.")
            }
            guard !step.dataset.contains("..") , !step.dataset.hasPrefix("/") else {
                throw CSVAnalysisError.unsupportedNotebook("Dataset paths stay inside the project.")
            }
        }
    }

    static func load(in root: URL, fileSystem: any WorkspaceFileSystem) async throws -> Self? {
        let entries = try await fileSystem.contentsOfDirectory(at: root, includingHiddenFiles: true)
        guard let entry = entries.first(where: { $0.url.lastPathComponent == Self.filename }) else { return nil }
        guard !entry.isDirectory, (entry.byteCount ?? 0) <= Self.byteLimit else {
            throw CSVAnalysisError.unsupportedNotebook("The notebook must be a JSON file smaller than 1 MB.")
        }
        let data = try await fileSystem.readFile(at: entry.url, maximumByteCount: Self.byteLimit + 1)
        guard data.count <= Self.byteLimit else {
            throw CSVAnalysisError.unsupportedNotebook("The notebook is too large to open.")
        }
        let notebook: Self
        do { notebook = try JSONDecoder().decode(Self.self, from: data) }
        catch {
            throw CSVAnalysisError.unsupportedNotebook("Could not read \(Self.filename): \(error.localizedDescription)")
        }
        try notebook.validate()
        return notebook
    }

    func save(in root: URL, fileSystem: any WorkspaceFileSystem) async throws {
        try self.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try Task.checkCancellation()
        try await fileSystem.writeFile(encoder.encode(self), to: root.appendingPathComponent(Self.filename))
    }
}
