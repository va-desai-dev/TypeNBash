import Foundation

/// Runs an `AnalysisStep` against a captured table.
///
/// Pure and `nonisolated`: it takes a snapshot in and hands a result back, so a
/// step runs off the main actor and nothing it touches can be edited underneath
/// it. Every row it declines to use is counted and reported — the kernel never
/// drops data quietly.
nonisolated enum AnalysisKernel {

    static func run(
        _ step: AnalysisStep,
        on snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String> = []
    ) throws -> AnalysisResult {
        var notes = Self.headerNotes(for: step, in: snapshot)
        let tables: [AnalysisResultTable]

        switch step.operation {
        case .describe(let columns):
            tables = try Self.describe(columns, step: step, snapshot: snapshot,
                                       missingCodes: missingCodes, notes: &notes)
        case .frequency(let column):
            tables = try Self.frequency(column, step: step, snapshot: snapshot,
                                        missingCodes: missingCodes, notes: &notes)
        case .crossTabulation(let rows, let columns):
            tables = try Self.crossTabulate(rows: rows, columns: columns, step: step, snapshot: snapshot,
                                            missingCodes: missingCodes, notes: &notes)
        case .chiSquareIndependence(let rows, let columns):
            tables = try Self.testIndependence(rows: rows, columns: columns, step: step, snapshot: snapshot,
                                               missingCodes: missingCodes, notes: &notes)
        case .correlation(let columns, let method):
            tables = try Self.correlate(columns, method: method, step: step, snapshot: snapshot,
                                        missingCodes: missingCodes, notes: &notes)
        case .oneSampleT(let column, let value):
            tables = try Self.oneSampleT(column, testValue: value, step: step, snapshot: snapshot,
                                         missingCodes: missingCodes, notes: &notes)
        case .independentT(let outcome, let group, let variance):
            tables = try Self.independentT(outcome: outcome, group: group, variance: variance, step: step,
                                           snapshot: snapshot, missingCodes: missingCodes, notes: &notes)
        case .pairedT(let first, let second):
            tables = try Self.pairedT(first, second, step: step, snapshot: snapshot,
                                      missingCodes: missingCodes, notes: &notes)
        case .oneWayANOVA(let outcome, let factor):
            tables = try Self.oneWayANOVA(outcome: outcome, factor: factor, step: step, snapshot: snapshot,
                                          missingCodes: missingCodes, notes: &notes)
        case .linearRegression(let outcome, let predictors):
            tables = try Self.regress(outcome: outcome, predictors: predictors, step: step,
                                      snapshot: snapshot, missingCodes: missingCodes, notes: &notes)
        }

        return AnalysisResult(
            stepID: step.id,
            title: step.title,
            tables: tables,
            notes: notes,
            input: snapshot.inputSummary(dataset: step.dataset, scope: step.scope)
        )
    }

    // MARK: Column resolution

    /// A step keeps the header it was written against. When the file has since
    /// changed, say so on the result instead of computing a different variable
    /// under the old name.
    private static func headerNotes(for step: AnalysisStep, in snapshot: CSVAnalysisSnapshot) -> [String] {
        step.columns.compactMap { reference in
            guard let header = snapshot.header(at: reference.index) else { return nil }
            guard header != reference.name else { return nil }
            return "Column \(reference.index + 1) now reads “\(header)”; this step was written for “\(reference.label)”."
        }
    }

    private static func numeric(
        _ reference: ColumnReference,
        _ snapshot: CSVAnalysisSnapshot,
        _ missingCodes: Set<String>
    ) throws -> CSVAnalysisSnapshot.NumericColumn {
        guard snapshot.header(at: reference.index) != nil else {
            throw CSVAnalysisError.datasetUnavailable("This table has no column \(reference.index + 1) (“\(reference.label)”).")
        }
        return try snapshot.numericColumn(at: reference.index, missingCodes: missingCodes)
    }

    private static func text(
        _ reference: ColumnReference,
        _ snapshot: CSVAnalysisSnapshot,
        _ missingCodes: Set<String>
    ) throws -> CSVAnalysisSnapshot.TextColumn {
        guard snapshot.header(at: reference.index) != nil else {
            throw CSVAnalysisError.datasetUnavailable("This table has no column \(reference.index + 1) (“\(reference.label)”).")
        }
        return try snapshot.textColumn(at: reference.index, missingCodes: missingCodes)
    }

    /// Rows the step is allowed to use, given its policy. `.listwise` resolves to
    /// one row set shared by every statistic; `.pairwise` leaves each statistic
    /// to its own complete rows; `.fail` refuses the step outright.
    private static func sharedRows(
        _ usable: [[Bool]],
        policy: MissingPolicy,
        rowCount: Int
    ) throws -> Set<Int>? {
        switch policy {
        case .pairwise:
            return nil
        case .listwise, .fail:
            var rows: Set<Int> = []
            for row in 0..<rowCount where usable.allSatisfy({ $0[row] }) { rows.insert(row) }
            if policy == .fail, rows.count != rowCount {
                throw CSVAnalysisError.missingValues(
                    "\(rowCount - rows.count) of \(rowCount) rows have a missing or unusable value, and this step is set to fail on missing.")
            }
            return rows
        }
    }

    private static func values(_ column: [Double?], limitedTo rows: Set<Int>?) -> [Double] {
        guard let rows else { return column.compactMap { $0 } }
        return column.indices.compactMap { rows.contains($0) ? column[$0] : nil }
    }

    // MARK: Descriptives

    private static func describe(
        _ references: [ColumnReference],
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        guard !references.isEmpty else { throw CSVAnalysisError.invalidColumn }
        let columns = try references.map { try Self.numeric($0, snapshot, missingCodes) }
        let rowCount = snapshot.table.rows.count
        let shared = try Self.sharedRows(columns.map { column in column.values.map { $0 != nil } },
                                         policy: step.missing, rowCount: rowCount)
        if let shared, step.missing == .listwise, shared.count != rowCount {
            notes.append("Listwise: \(rowCount - shared.count) of \(rowCount) rows dropped for being incomplete across all \(references.count) columns.")
        }

        var rows: [[AnalysisCell]] = []
        for (reference, column) in zip(references, columns) {
            let sample = Self.values(column.values, limitedTo: shared)
            let summary = Statistics.describe(sample)
            if step.missing == .pairwise, !column.missingRows.isEmpty || !column.invalidRows.isEmpty {
                notes.append("\(reference.label): \(column.missingRows.count) missing, \(column.invalidRows.count) unusable of \(rowCount) rows.")
            } else if !column.invalidRows.isEmpty {
                notes.append("\(reference.label): \(column.invalidRows.count) cells were not numbers.")
            }
            rows.append([
                .text(reference.label),
                .count(sample.count),
                .count(column.missingRows.count),
                .count(column.invalidRows.count),
                summary.mean.map(AnalysisCell.number) ?? .missing,
                summary.standardDeviation.map(AnalysisCell.number) ?? .missing,
                summary.minimum.map(AnalysisCell.number) ?? .missing,
                summary.lowerQuartile.map(AnalysisCell.number) ?? .missing,
                summary.median.map(AnalysisCell.number) ?? .missing,
                summary.upperQuartile.map(AnalysisCell.number) ?? .missing,
                summary.maximum.map(AnalysisCell.number) ?? .missing,
            ])
        }
        return [AnalysisResultTable(
            caption: "Quartiles use linear interpolation; the deviation is the sample SD.",
            columns: ["Variable", "N", "Missing", "Unusable", "Mean", "SD", "Min", "Q1", "Median", "Q3", "Max"],
            rows: rows
        )]
    }

    // MARK: Frequencies

    private static let levelLimit = 500

    private static func frequency(
        _ reference: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let column = try Self.text(reference, snapshot, missingCodes)
        let present = column.values.compactMap { $0 }
        var counts: [String: Int] = [:]
        for level in present { counts[level, default: 0] += 1 }
        guard counts.count <= Self.levelLimit else {
            throw CSVAnalysisError.tooManyLevels(
                "“\(reference.label)” has \(counts.count) distinct values. Frequencies are limited to \(Self.levelLimit) levels — this column looks continuous rather than categorical.")
        }
        if !column.missingRows.isEmpty {
            notes.append("\(column.missingRows.count) of \(column.values.count) rows are missing and are excluded from the percentages.")
        }

        let ordered = counts.sorted {
            $0.value == $1.value ? $0.key.localizedStandardCompare($1.key) == .orderedAscending : $0.value > $1.value
        }
        var cumulative = 0
        let total = max(present.count, 1)
        let rows = ordered.map { level, count -> [AnalysisCell] in
            cumulative += count
            return [.text(level), .count(count),
                    .number(Double(count) / Double(total) * 100),
                    .number(Double(cumulative) / Double(total) * 100)]
        }
        return [AnalysisResultTable(
            caption: "Percentages are of the \(present.count) non-missing rows.",
            columns: [reference.label, "Count", "%", "Cumulative %"],
            rows: rows
        )]
    }

    // MARK: Cross-tabulation

    private static let crossTabLevelLimit = 60

    private static func crossTabulate(
        rows rowReference: ColumnReference,
        columns columnReference: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let rowColumn = try Self.text(rowReference, snapshot, missingCodes)
        let columnColumn = try Self.text(columnReference, snapshot, missingCodes)
        let rowCount = snapshot.table.rows.count

        // A cross-tabulation is inherently paired: a row missing either variable
        // has no cell to land in under any policy. Only `.fail` changes what that
        // means, by refusing the step rather than reporting the exclusions below.
        if step.missing == .fail {
            _ = try Self.sharedRows([rowColumn.values.map { $0 != nil }, columnColumn.values.map { $0 != nil }],
                                    policy: .fail, rowCount: rowCount)
        }

        var counts: [String: [String: Int]] = [:]
        var rowLevels: Set<String> = []
        var columnLevels: Set<String> = []
        var dropped = 0
        for index in 0..<rowCount {
            guard let rowLevel = rowColumn.values[index], let columnLevel = columnColumn.values[index] else {
                dropped += 1
                continue
            }
            rowLevels.insert(rowLevel)
            columnLevels.insert(columnLevel)
            counts[rowLevel, default: [:]][columnLevel, default: 0] += 1
        }
        guard rowLevels.count <= Self.crossTabLevelLimit, columnLevels.count <= Self.crossTabLevelLimit else {
            throw CSVAnalysisError.tooManyLevels(
                "A cross-tabulation is limited to \(Self.crossTabLevelLimit) levels per axis; this pair has \(rowLevels.count) × \(columnLevels.count).")
        }
        if dropped > 0 {
            notes.append("\(dropped) of \(rowCount) rows are missing one or both variables and are excluded.")
        }

        let orderedRows = rowLevels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let orderedColumns = columnLevels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        var table: [[AnalysisCell]] = orderedRows.map { rowLevel in
            let cells = orderedColumns.map { AnalysisCell.count(counts[rowLevel]?[$0] ?? 0) }
            let total = orderedColumns.reduce(0) { $0 + (counts[rowLevel]?[$1] ?? 0) }
            return [.text(rowLevel)] + cells + [.count(total)]
        }
        let columnTotals = orderedColumns.map { columnLevel in
            orderedRows.reduce(0) { $0 + (counts[$1]?[columnLevel] ?? 0) }
        }
        table.append([.text("Total")] + columnTotals.map(AnalysisCell.count) + [.count(columnTotals.reduce(0, +))])

        return [AnalysisResultTable(
            caption: "Counts of \(rowReference.label) (rows) by \(columnReference.label) (columns). "
                + "This describes the table; run a chi-square step to test it.",
            columns: ["\(rowReference.label) ╲ \(columnReference.label)"] + orderedColumns + ["Total"],
            rows: table
        )]
    }


    // MARK: Correlation

    private static func correlate(
        _ references: [ColumnReference],
        method: CorrelationMethod,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        guard references.count >= 2 else {
            throw CSVAnalysisError.notEnoughData("A correlation needs at least two columns.")
        }
        let columns = try references.map { try Self.numeric($0, snapshot, missingCodes) }
        let rowCount = snapshot.table.rows.count
        let shared = try Self.sharedRows(columns.map { column in column.values.map { $0 != nil } },
                                         policy: step.missing, rowCount: rowCount)
        if let shared, shared.count != rowCount {
            notes.append("Listwise: \(rowCount - shared.count) of \(rowCount) rows dropped for being incomplete across all \(references.count) columns.")
        } else if shared == nil {
            notes.append("Pairwise: each coefficient uses the rows complete for its own two variables, so N varies by pair.")
        }

        // Each unordered pair is one test. They are collected first so the
        // multiplicity adjustment sees the whole family before anything prints.
        struct Test {
            let row: Int, column: Int
            let coefficient: Double?
            let count: Int
        }
        var tests: [Test] = []
        var coefficients: [[AnalysisCell]] = []
        var undefined: [String] = []
        for (rowIndex, rowReference) in references.enumerated() {
            var coefficientRow: [AnalysisCell] = [.text(rowReference.label)]
            for columnIndex in references.indices {
                let pair = Self.completePairs(columns[rowIndex].values, columns[columnIndex].values, limitedTo: shared)
                if rowIndex == columnIndex {
                    coefficientRow.append(pair.left.count >= 2 ? .number(1) : .missing)
                    continue
                }
                let value = Statistics.correlation(pair.left, pair.right, method: method)
                coefficientRow.append(value.map(AnalysisCell.number) ?? .missing)
                if value == nil {
                    undefined.append("\(rowReference.label) × \(references[columnIndex].label)")
                }
                if rowIndex < columnIndex {
                    tests.append(Test(row: rowIndex, column: columnIndex,
                                      coefficient: value, count: pair.left.count))
                }
            }
            coefficients.append(coefficientRow)
        }
        if !undefined.isEmpty {
            let pairs = Set(undefined).sorted().joined(separator: ", ")
            notes.append("Undefined for \(pairs) — fewer than two complete pairs, or a variable with no spread.")
        }

        let statistics = tests.map { test -> Statistics.CorrelationTest? in
            guard let coefficient = test.coefficient else { return nil }
            return Statistics.test(coefficient, count: test.count, method: method)
        }
        let raw = statistics.map { $0?.p ?? Double.nan }
        let adjusted = step.adjustment.adjusted(raw)
        let adjusting = step.adjustment != .none && tests.count > 1
        if adjusting {
            notes.append("\(tests.count) simultaneous tests; p adjusted by \(step.adjustment.rawValue).")
        }

        var testColumns = ["Variable", "Variable", "N", "r", "df", "t", "p"]
        if adjusting { testColumns.append("p (\(step.adjustment.rawValue))") }
        testColumns += ["95% CI low", "95% CI high"]
        let testRows = tests.enumerated().map { position, test -> [AnalysisCell] in
            let statistic = statistics[position]
            var row: [AnalysisCell] = [
                .text(references[test.row].label),
                .text(references[test.column].label),
                .count(test.count),
                test.coefficient.map(AnalysisCell.number) ?? .missing,
                statistic.map { AnalysisCell.count($0.degreesOfFreedom) } ?? .missing,
                statistic.map { AnalysisCell.number($0.t) } ?? .missing,
                statistic.map { AnalysisCell.probability($0.p) } ?? .missing,
            ]
            if adjusting {
                row.append(adjusted[position].isNaN ? .missing : .probability(adjusted[position]))
            }
            row.append(statistic?.lowerBound.map(AnalysisCell.number) ?? .missing)
            row.append(statistic?.upperBound.map(AnalysisCell.number) ?? .missing)
            return row
        }

        var caption = "Two-sided tests of H₀: ρ = 0, with Fisher z intervals."
        if method == .spearman {
            caption += " Spearman uses the t approximation and the Bonett–Wright interval, both of which are asymptotic."
        }

        return [
            AnalysisResultTable(
                caption: "\(method.rawValue) coefficients.",
                columns: [""] + references.map(\.label),
                rows: coefficients
            ),
            AnalysisResultTable(caption: caption, columns: testColumns, rows: testRows),
        ]
    }

    // MARK: Independence

    private static func testIndependence(
        rows rowReference: ColumnReference,
        columns columnReference: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let rowColumn = try Self.text(rowReference, snapshot, missingCodes)
        let columnColumn = try Self.text(columnReference, snapshot, missingCodes)
        let rowCount = snapshot.table.rows.count
        if step.missing == .fail {
            _ = try Self.sharedRows([rowColumn.values.map { $0 != nil }, columnColumn.values.map { $0 != nil }],
                                    policy: .fail, rowCount: rowCount)
        }

        var counts: [String: [String: Int]] = [:]
        var rowLevels: Set<String> = []
        var columnLevels: Set<String> = []
        var dropped = 0
        for index in 0..<rowCount {
            guard let rowLevel = rowColumn.values[index], let columnLevel = columnColumn.values[index] else {
                dropped += 1
                continue
            }
            rowLevels.insert(rowLevel)
            columnLevels.insert(columnLevel)
            counts[rowLevel, default: [:]][columnLevel, default: 0] += 1
        }
        guard rowLevels.count >= 2, columnLevels.count >= 2 else {
            throw CSVAnalysisError.notEnoughData("A test of independence needs at least two levels in each variable.")
        }
        guard rowLevels.count <= Self.crossTabLevelLimit, columnLevels.count <= Self.crossTabLevelLimit else {
            throw CSVAnalysisError.tooManyLevels(
                "A test of independence is limited to \(Self.crossTabLevelLimit) levels per axis; this pair has \(rowLevels.count) × \(columnLevels.count).")
        }
        if dropped > 0 {
            notes.append("\(dropped) of \(rowCount) rows are missing one or both variables and are excluded.")
        }

        let orderedRows = rowLevels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let orderedColumns = columnLevels.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        let rowTotals = orderedRows.map { row in orderedColumns.reduce(0) { $0 + (counts[row]?[$1] ?? 0) } }
        let columnTotals = orderedColumns.map { column in orderedRows.reduce(0) { $0 + (counts[$1]?[column] ?? 0) } }
        let grand = rowTotals.reduce(0, +)
        guard grand > 0 else { throw CSVAnalysisError.notEnoughData("No complete rows to test.") }

        // The expected-count rule is reported, never enforced: a sparse table is
        // the analyst's call, and silently refusing to compute is its own error.
        var chiSquare = 0.0
        var sparse = 0
        var expectedRows: [[AnalysisCell]] = []
        for (rowIndex, rowLevel) in orderedRows.enumerated() {
            var expectedRow: [AnalysisCell] = [.text(rowLevel)]
            for (columnIndex, columnLevel) in orderedColumns.enumerated() {
                let expected = Double(rowTotals[rowIndex]) * Double(columnTotals[columnIndex]) / Double(grand)
                expectedRow.append(.number(expected))
                guard expected > 0 else { continue }
                if expected < 5 { sparse += 1 }
                let observed = Double(counts[rowLevel]?[columnLevel] ?? 0)
                chiSquare += (observed - expected) * (observed - expected) / expected
            }
            expectedRows.append(expectedRow)
        }
        let degreesOfFreedom = (orderedRows.count - 1) * (orderedColumns.count - 1)
        let smaller = Double(min(orderedRows.count, orderedColumns.count) - 1)
        if sparse > 0 {
            notes.append("\(sparse) of \(orderedRows.count * orderedColumns.count) cells expect fewer than 5 observations, so the chi-square approximation is unreliable here.")
        }

        return [
            AnalysisResultTable(
                caption: "Pearson's chi-square test of independence, two-sided.",
                columns: ["χ²", "df", "N", "p", "Cramér's V"],
                rows: [[.number(chiSquare), .count(degreesOfFreedom), .count(grand),
                        .probability(Distributions.upperChiSquare(chiSquare, df: Double(degreesOfFreedom))),
                        .number((chiSquare / (Double(grand) * smaller)).squareRoot())]]
            ),
            AnalysisResultTable(
                caption: "Expected counts under independence.",
                columns: ["\(rowReference.label) ╲ \(columnReference.label)"] + orderedColumns,
                rows: expectedRows
            ),
        ]
    }

    // MARK: Comparing means

    private static let groupLimit = 50

    /// Splits an outcome by a grouping column, keeping only rows complete in
    /// both. Every mean comparison is paired in that sense, so this is where
    /// `.fail` gets its chance to refuse the step.
    private static func groups(
        outcome: ColumnReference,
        factor: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [(level: String, values: [Double])] {
        let values = try Self.numeric(outcome, snapshot, missingCodes)
        let labels = try Self.text(factor, snapshot, missingCodes)
        let rowCount = snapshot.table.rows.count
        if step.missing == .fail {
            _ = try Self.sharedRows([values.values.map { $0 != nil }, labels.values.map { $0 != nil }],
                                    policy: .fail, rowCount: rowCount)
        }
        var collected: [String: [Double]] = [:]
        var order: [String] = []
        var dropped = 0
        for index in 0..<rowCount {
            guard let value = values.values[index], let label = labels.values[index] else {
                dropped += 1
                continue
            }
            if collected[label] == nil { order.append(label) }
            collected[label, default: []].append(value)
        }
        guard !collected.isEmpty else {
            throw CSVAnalysisError.notEnoughData("No rows have both \(outcome.label) and \(factor.label).")
        }
        guard collected.count <= Self.groupLimit else {
            throw CSVAnalysisError.tooManyLevels(
                "\(factor.label) has \(collected.count) levels. Grouping is limited to \(Self.groupLimit); this looks like an identifier rather than a factor.")
        }
        if dropped > 0 {
            notes.append("\(dropped) of \(rowCount) rows are missing the outcome or the group and are excluded.")
        }
        if !values.invalidRows.isEmpty {
            notes.append("\(values.invalidRows.count) cells of \(outcome.label) were not numbers.")
        }
        let ordered = order.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        return ordered.map { (level: $0, values: collected[$0] ?? []) }
    }

    private static func groupDescriptives(_ groups: [(level: String, values: [Double])],
                                          label: String) -> AnalysisResultTable {
        AnalysisResultTable(
            caption: nil,
            columns: [label, "N", "Mean", "SD", "SE"],
            rows: groups.map { group in
                let summary = Statistics.describe(group.values)
                let standardError = summary.standardDeviation.map { $0 / Double(group.values.count).squareRoot() }
                return [.text(group.level), .count(group.values.count),
                        summary.mean.map(AnalysisCell.number) ?? .missing,
                        summary.standardDeviation.map(AnalysisCell.number) ?? .missing,
                        standardError.map(AnalysisCell.number) ?? .missing]
            }
        )
    }

    private static func oneSampleT(
        _ reference: ColumnReference,
        testValue: Double,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let column = try Self.numeric(reference, snapshot, missingCodes)
        let sample = column.values.compactMap { $0 }
        if !column.missingRows.isEmpty || !column.invalidRows.isEmpty {
            notes.append("\(reference.label): \(column.missingRows.count) missing, \(column.invalidRows.count) unusable of \(column.values.count) rows.")
        }
        if step.missing == .fail, sample.count != column.values.count {
            throw CSVAnalysisError.missingValues(
                "\(column.values.count - sample.count) rows are missing or unusable, and this step is set to fail on missing.")
        }
        guard let test = Statistics.oneSampleT(sample, testValue: testValue) else {
            throw CSVAnalysisError.notEnoughData("A one-sample t test needs at least two usable values with some spread.")
        }
        return [AnalysisResultTable(
            caption: "Two-sided test of H₀: μ = \(testValue).",
            columns: ["N", "Mean", "SD", "Mean − \(testValue)", "t", "df", "p", "95% CI low", "95% CI high"],
            rows: [[.count(sample.count), .number(test.mean), .number(test.standardDeviation),
                    .number(test.difference), .number(test.t), .count(test.degreesOfFreedom),
                    .probability(test.p), .number(test.lowerBound), .number(test.upperBound)]]
        )]
    }

    private static func independentT(
        outcome: ColumnReference,
        group: ColumnReference,
        variance: VarianceAssumption,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let groups = try Self.groups(outcome: outcome, factor: group, step: step,
                                     snapshot: snapshot, missingCodes: missingCodes, notes: &notes)
        // Two levels is the test's definition, not a detail to paper over by
        // quietly switching to an ANOVA.
        guard groups.count == 2 else {
            throw CSVAnalysisError.notEnoughData(
                "\(group.label) has \(groups.count) level\(groups.count == 1 ? "" : "s"). An independent-samples t test needs exactly two; use One-Way ANOVA for more.")
        }
        guard let test = Statistics.independentT(groups[0].values, groups[1].values, variance: variance) else {
            throw CSVAnalysisError.notEnoughData("Each group needs at least two usable values with some spread.")
        }
        var tables = [Self.groupDescriptives(groups, label: group.label)]
        tables.append(AnalysisResultTable(
            caption: "\(variance.rawValue) two-sided test of H₀: μ₁ = μ₂, as \(groups[0].level) − \(groups[1].level).",
            columns: ["Difference", "SE", "t", "df", "p", "95% CI low", "95% CI high"],
            rows: [[.number(test.difference), .number(test.standardError), .number(test.t),
                    .number(test.degreesOfFreedom), .probability(test.p),
                    .number(test.lowerBound), .number(test.upperBound)]]
        ))
        if let levene = Statistics.levene(groups.map(\.values)) {
            tables.append(AnalysisResultTable(
                caption: "Levene's test of equal variances. A small p is a reason to prefer Welch; it does not decide the test for you.",
                columns: ["F", "df1", "df2", "p"],
                rows: [[.number(levene.f), .count(levene.numeratorDF), .count(levene.denominatorDF),
                        .probability(levene.p)]]
            ))
        }
        return tables
    }

    private static func pairedT(
        _ first: ColumnReference,
        _ second: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let left = try Self.numeric(first, snapshot, missingCodes)
        let right = try Self.numeric(second, snapshot, missingCodes)
        let rowCount = snapshot.table.rows.count
        if step.missing == .fail {
            _ = try Self.sharedRows([left.values.map { $0 != nil }, right.values.map { $0 != nil }],
                                    policy: .fail, rowCount: rowCount)
        }
        // A pair with either half absent is not a pair, under any policy.
        let pairs = Self.completePairs(left.values, right.values, limitedTo: nil)
        if pairs.left.count != rowCount {
            notes.append("\(rowCount - pairs.left.count) of \(rowCount) rows are incomplete in one column and are excluded.")
        }
        let differences = zip(pairs.left, pairs.right).map(-)
        guard let test = Statistics.oneSampleT(differences, testValue: 0) else {
            throw CSVAnalysisError.notEnoughData("A paired t test needs at least two complete pairs that are not all identical.")
        }
        return [AnalysisResultTable(
            caption: "Two-sided test of H₀: μ difference = 0, as \(first.label) − \(second.label).",
            columns: ["Pairs", "Mean difference", "SD", "SE", "t", "df", "p", "95% CI low", "95% CI high"],
            rows: [[.count(differences.count), .number(test.mean), .number(test.standardDeviation),
                    .number(test.standardError), .number(test.t), .count(test.degreesOfFreedom),
                    .probability(test.p), .number(test.lowerBound), .number(test.upperBound)]]
        )]
    }

    private static func oneWayANOVA(
        outcome: ColumnReference,
        factor: ColumnReference,
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        let groups = try Self.groups(outcome: outcome, factor: factor, step: step,
                                     snapshot: snapshot, missingCodes: missingCodes, notes: &notes)
        guard groups.count >= 2 else {
            throw CSVAnalysisError.notEnoughData("A one-way ANOVA needs at least two groups.")
        }
        guard let model = Statistics.oneWayANOVA(groups.map(\.values)) else {
            throw CSVAnalysisError.notEnoughData("Each group needs at least one value, and the groups together need some spread.")
        }
        notes.append("Assumes equal variances across groups; Levene's test is reported with the independent-samples t test.")
        return [
            Self.groupDescriptives(groups, label: factor.label),
            AnalysisResultTable(
                caption: "One-way analysis of variance. η² is the share of variance the grouping accounts for.",
                columns: ["Source", "SS", "df", "MS", "F", "p", "η²"],
                rows: [
                    [.text("Between groups"), .number(model.betweenSumOfSquares), .count(model.numeratorDF),
                     .number(model.betweenMeanSquare), .number(model.f), .probability(model.p),
                     .number(model.etaSquared)],
                    [.text("Within groups"), .number(model.withinSumOfSquares), .count(model.denominatorDF),
                     .number(model.withinMeanSquare), .missing, .missing, .missing],
                    [.text("Total"), .number(model.betweenSumOfSquares + model.withinSumOfSquares),
                     .count(model.numeratorDF + model.denominatorDF), .missing, .missing, .missing, .missing],
                ]
            ),
        ]
    }

    // MARK: Regression

    private static let factorLevelLimit = 30

    private static func regress(
        outcome outcomeReference: ColumnReference,
        predictors: [RegressionPredictor],
        step: AnalysisStep,
        snapshot: CSVAnalysisSnapshot,
        missingCodes: Set<String>,
        notes: inout [String]
    ) throws -> [AnalysisResultTable] {
        guard !predictors.isEmpty else {
            throw CSVAnalysisError.notEnoughData("A regression needs at least one predictor.")
        }
        guard !predictors.contains(where: { $0.column.index == outcomeReference.index }) else {
            throw CSVAnalysisError.invalidStep("The outcome cannot also be a predictor.")
        }
        let outcomeColumn = try Self.numeric(outcomeReference, snapshot, missingCodes)
        let rowCount = snapshot.table.rows.count

        // Read each predictor the way it was declared, not the way it parses.
        enum Term {
            case numeric(CSVAnalysisSnapshot.NumericColumn)
            case categorical(CSVAnalysisSnapshot.TextColumn)

            var present: [Bool] {
                switch self {
                    case .numeric(let column): column.values.map { $0 != nil }
                    case .categorical(let column): column.values.map { $0 != nil }
                }
            }
        }
        let terms: [Term] = try predictors.map { predictor in
            predictor.isCategorical
                ? .categorical(try Self.text(predictor.column, snapshot, missingCodes))
                : .numeric(try Self.numeric(predictor.column, snapshot, missingCodes))
        }

        // Complete-case by construction: a row missing any term has no place in
        // the design matrix under any policy.
        let usable = try Self.sharedRows([outcomeColumn.values.map { $0 != nil }] + terms.map(\.present),
                                         policy: step.missing == .fail ? .fail : .listwise,
                                         rowCount: rowCount) ?? []
        let ordered = usable.sorted()
        if ordered.count != rowCount {
            notes.append("\(rowCount - ordered.count) of \(rowCount) rows are incomplete across the outcome and predictors and are excluded.")
        }

        var design: [[Double]] = []
        var names: [String] = []
        var multiLevelFactors = 0
        for (predictor, term) in zip(predictors, terms) {
            switch term {
                case .numeric(let column):
                    design.append(ordered.map { column.values[$0] ?? 0 })
                    names.append(predictor.column.label)
                case .categorical(let column):
                    let present = ordered.compactMap { column.values[$0] }
                    let levels = Set(present).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
                    guard levels.count >= 2 else {
                        throw CSVAnalysisError.notEnoughData(
                            "\(predictor.column.label) has only one level among the usable rows, so it cannot be a predictor.")
                    }
                    guard levels.count <= Self.factorLevelLimit else {
                        throw CSVAnalysisError.tooManyLevels(
                            "\(predictor.column.label) has \(levels.count) levels. A categorical predictor is limited to \(Self.factorLevelLimit); this looks like an identifier.")
                    }
                    let reference = predictor.referenceLevel ?? levels[0]
                    guard levels.contains(reference) else {
                        throw CSVAnalysisError.invalidStep(
                            "\(predictor.column.label) has no level “\(reference)” to hold out. Available: \(levels.joined(separator: ", ")).")
                    }
                    // One indicator per level except the reference. Coding all of
                    // them would make the design exactly rank deficient against
                    // the intercept, which is the whole reason a baseline exists.
                    for level in levels where level != reference {
                        design.append(present.map { $0 == level ? 1 : 0 })
                        names.append("\(predictor.column.label) = \(level)")
                    }
                    notes.append("\(predictor.column.label) is dummy coded against “\(reference)”; each coefficient is the difference from that level.")
                    if levels.count > 2 { multiLevelFactors += 1 }
            }
        }

        guard let model = Statistics.regression(outcome: ordered.map { outcomeColumn.values[$0] ?? 0 },
                                                predictors: design, names: names) else {
            throw CSVAnalysisError.notEnoughData(
                "Could not fit: the predictors are collinear, the outcome has no spread, or there are too few complete rows for \(design.count) term\(design.count == 1 ? "" : "s") plus an intercept.")
        }
        if let worst = model.terms.compactMap(\.varianceInflation).max(), worst >= 10 {
            notes.append("Highest variance inflation is \(String(format: "%.1f", worst)). Above about 10 the predictors overlap enough that individual coefficients are hard to read, even though the fit is sound.")
        }
        if multiLevelFactors > 0 {
            notes.append("Inflation factors are per indicator, not per variable, so for a factor with more than two levels they shift with the reference level. A generalized VIF would be the term-level measure.")
        }

        var coefficientColumns = ["Term", "B", "SE", "β", "t", "p", "95% CI low", "95% CI high"]
        let reportsInflation = model.terms.contains { $0.varianceInflation != nil }
        if reportsInflation { coefficientColumns.append("VIF") }

        let total = model.regressionSumOfSquares + model.residualSumOfSquares
        return [
            AnalysisResultTable(
                caption: "Ordinary least squares with an intercept.",
                columns: ["N", "R", "R²", "Adjusted R²", "SE of estimate"],
                rows: [[.count(model.observations), .number(model.rSquared.squareRoot()),
                        .number(model.rSquared), .number(model.adjustedRSquared),
                        .number(model.residualStandardError)]]
            ),
            AnalysisResultTable(
                caption: "Does the model explain more than nothing?",
                columns: ["Source", "SS", "df", "MS", "F", "p"],
                rows: [
                    [.text("Regression"), .number(model.regressionSumOfSquares), .count(model.numeratorDF),
                     .number(model.regressionSumOfSquares / Double(model.numeratorDF)),
                     .number(model.f), .probability(model.p)],
                    [.text("Residual"), .number(model.residualSumOfSquares), .count(model.denominatorDF),
                     .number(model.residualSumOfSquares / Double(model.denominatorDF)), .missing, .missing],
                    [.text("Total"), .number(total),
                     .count(model.numeratorDF + model.denominatorDF), .missing, .missing, .missing],
                ]
            ),
            AnalysisResultTable(
                caption: "β is the coefficient in standard deviations." + (reportsInflation
                    ? " VIF is how far collinearity widens each standard error." : ""),
                columns: coefficientColumns,
                rows: model.terms.map { term in
                    var row: [AnalysisCell] = [
                        .text(term.name), .number(term.estimate), .number(term.standardError),
                        term.standardized.map(AnalysisCell.number) ?? .missing,
                        .number(term.t), .probability(term.p),
                        .number(term.lowerBound), .number(term.upperBound),
                    ]
                    if reportsInflation {
                        row.append(term.varianceInflation.map(AnalysisCell.number) ?? .missing)
                    }
                    return row
                }
            ),
        ]
    }

    private static func completePairs(
        _ left: [Double?],
        _ right: [Double?],
        limitedTo rows: Set<Int>?
    ) -> (left: [Double], right: [Double]) {
        var leftValues: [Double] = []
        var rightValues: [Double] = []
        for index in left.indices {
            if let rows, !rows.contains(index) { continue }
            guard let a = left[index], let b = right[index] else { continue }
            leftValues.append(a)
            rightValues.append(b)
        }
        return (leftValues, rightValues)
    }
}

/// The arithmetic, with no notion of steps, columns or CSV.
///
/// Separated so the formulas can be read and checked on their own, and so a
/// later inferential layer adds distribution functions here rather than
/// threading them through the operations above.
nonisolated enum Statistics {

    struct Summary: Sendable {
        var mean: Double?
        var standardDeviation: Double?
        var minimum: Double?
        var lowerQuartile: Double?
        var median: Double?
        var upperQuartile: Double?
        var maximum: Double?
    }

    static func describe(_ values: [Double]) -> Summary {
        guard !values.isEmpty else { return Summary() }
        let sorted = values.sorted()
        let mean = values.reduce(0, +) / Double(values.count)
        return Summary(
            mean: mean,
            standardDeviation: Self.standardDeviation(values, mean: mean),
            minimum: sorted.first,
            lowerQuartile: Self.quantile(sorted, 0.25),
            median: Self.quantile(sorted, 0.5),
            upperQuartile: Self.quantile(sorted, 0.75),
            maximum: sorted.last
        )
    }

    /// Sample standard deviation; undefined for a single observation.
    static func standardDeviation(_ values: [Double], mean: Double) -> Double? {
        guard values.count >= 2 else { return nil }
        let sumOfSquares = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        return (sumOfSquares / Double(values.count - 1)).squareRoot()
    }

    /// Linearly interpolated quantile of an already-sorted sample — the default
    /// definition in R and NumPy, so results match what a user would get there.
    static func quantile(_ sorted: [Double], _ probability: Double) -> Double? {
        guard let first = sorted.first, let last = sorted.last else { return nil }
        guard sorted.count > 1 else { return first }
        let position = Double(sorted.count - 1) * probability
        let lower = Int(position.rounded(.down))
        guard lower + 1 < sorted.count else { return last }
        return sorted[lower] + (position - Double(lower)) * (sorted[lower + 1] - sorted[lower])
    }

    struct MeanTest: Sendable {
        var mean = 0.0
        var standardDeviation = 0.0
        var standardError = 0.0
        var difference = 0.0
        var t = 0.0
        var degreesOfFreedom = 0
        var p = 0.0
        var lowerBound = 0.0
        var upperBound = 0.0
    }

    /// A one-sample t test, which is also the paired test once the pairs have
    /// been differenced — a paired comparison is a one-sample test on the
    /// differences, not a two-sample test on the columns.
    static func oneSampleT(_ values: [Double], testValue: Double) -> MeanTest? {
        guard values.count >= 2 else { return nil }
        let count = Double(values.count)
        let mean = values.reduce(0, +) / count
        guard let deviation = Self.standardDeviation(values, mean: mean), deviation > 0 else { return nil }
        let standardError = deviation / count.squareRoot()
        let degreesOfFreedom = values.count - 1
        let difference = mean - testValue
        let t = difference / standardError
        let half = Distributions.inverseT(0.975, df: Double(degreesOfFreedom)) * standardError
        return MeanTest(mean: mean, standardDeviation: deviation, standardError: standardError,
                        difference: difference, t: t, degreesOfFreedom: degreesOfFreedom,
                        p: Distributions.twoTailedT(t, df: Double(degreesOfFreedom)),
                        lowerBound: difference - half, upperBound: difference + half)
    }

    struct TwoSampleTest: Sendable {
        let difference: Double
        let standardError: Double
        let t: Double
        /// Fractional under Welch, which is why this is not an `Int`.
        let degreesOfFreedom: Double
        let p: Double
        let lowerBound: Double
        let upperBound: Double
    }

    /// Welch does not assume equal variances and uses the Welch–Satterthwaite
    /// degrees of freedom, which are fractional. The pooled test assumes they
    /// are equal and recovers the classical integer df.
    static func independentT(_ left: [Double], _ right: [Double],
                             variance: VarianceAssumption) -> TwoSampleTest? {
        guard left.count >= 2, right.count >= 2 else { return nil }
        let leftCount = Double(left.count), rightCount = Double(right.count)
        let leftMean = left.reduce(0, +) / leftCount
        let rightMean = right.reduce(0, +) / rightCount
        guard let leftDeviation = Self.standardDeviation(left, mean: leftMean),
              let rightDeviation = Self.standardDeviation(right, mean: rightMean) else { return nil }
        let leftVariance = leftDeviation * leftDeviation, rightVariance = rightDeviation * rightDeviation
        let standardError: Double, degreesOfFreedom: Double
        switch variance {
        case .welch:
            let leftTerm = leftVariance / leftCount, rightTerm = rightVariance / rightCount
            standardError = (leftTerm + rightTerm).squareRoot()
            let numerator = (leftTerm + rightTerm) * (leftTerm + rightTerm)
            let denominator = leftTerm * leftTerm / (leftCount - 1) + rightTerm * rightTerm / (rightCount - 1)
            degreesOfFreedom = denominator > 0 ? numerator / denominator : 0
        case .pooled:
            let pooled = ((leftCount - 1) * leftVariance + (rightCount - 1) * rightVariance)
                / (leftCount + rightCount - 2)
            standardError = (pooled * (1 / leftCount + 1 / rightCount)).squareRoot()
            degreesOfFreedom = leftCount + rightCount - 2
        }
        guard standardError > 0, degreesOfFreedom > 0 else { return nil }
        let difference = leftMean - rightMean
        let t = difference / standardError
        let half = Distributions.inverseT(0.975, df: degreesOfFreedom) * standardError
        return TwoSampleTest(difference: difference, standardError: standardError, t: t,
                             degreesOfFreedom: degreesOfFreedom,
                             p: Distributions.twoTailedT(t, df: degreesOfFreedom),
                             lowerBound: difference - half, upperBound: difference + half)
    }

    struct VarianceTest: Sendable {
        let f: Double
        let numeratorDF: Int
        let denominatorDF: Int
        let p: Double
    }

    /// Levene's test on absolute deviations from each group's mean, as SPSS
    /// reports it. It is a reason to prefer one test over another, never a rule
    /// that picks one.
    static func levene(_ groups: [[Double]]) -> VarianceTest? {
        let usable = groups.filter { $0.count >= 2 }
        guard usable.count >= 2 else { return nil }
        let deviations = usable.map { group -> [Double] in
            let mean = group.reduce(0, +) / Double(group.count)
            return group.map { abs($0 - mean) }
        }
        guard let ratio = Self.fRatio(deviations) else { return nil }
        return VarianceTest(f: ratio.f, numeratorDF: ratio.numeratorDF,
                            denominatorDF: ratio.denominatorDF, p: ratio.p)
    }

    struct ANOVA: Sendable {
        let betweenSumOfSquares: Double
        let withinSumOfSquares: Double
        let betweenMeanSquare: Double
        let withinMeanSquare: Double
        let numeratorDF: Int
        let denominatorDF: Int
        let f: Double
        let p: Double
        let etaSquared: Double
    }

    static func oneWayANOVA(_ groups: [[Double]]) -> ANOVA? {
        guard let ratio = Self.fRatio(groups) else { return nil }
        let total = ratio.between + ratio.within
        return ANOVA(betweenSumOfSquares: ratio.between, withinSumOfSquares: ratio.within,
                     betweenMeanSquare: ratio.between / Double(ratio.numeratorDF),
                     withinMeanSquare: ratio.within / Double(ratio.denominatorDF),
                     numeratorDF: ratio.numeratorDF, denominatorDF: ratio.denominatorDF,
                     f: ratio.f, p: ratio.p, etaSquared: total > 0 ? ratio.between / total : 0)
    }

    /// The one-way decomposition shared by ANOVA and Levene: Levene is an
    /// analysis of variance on absolute deviations.
    private static func fRatio(_ groups: [[Double]])
        -> (between: Double, within: Double, numeratorDF: Int, denominatorDF: Int, f: Double, p: Double)? {
        let usable = groups.filter { !$0.isEmpty }
        guard usable.count >= 2 else { return nil }
        let total = usable.reduce(0) { $0 + $1.count }
        let numeratorDF = usable.count - 1
        let denominatorDF = total - usable.count
        guard denominatorDF > 0 else { return nil }
        let grandMean = usable.flatMap { $0 }.reduce(0, +) / Double(total)
        var between = 0.0, within = 0.0
        for group in usable {
            let mean = group.reduce(0, +) / Double(group.count)
            between += Double(group.count) * (mean - grandMean) * (mean - grandMean)
            within += group.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        }
        guard within > 0 else { return nil }
        let f = (between / Double(numeratorDF)) / (within / Double(denominatorDF))
        return (between, within, numeratorDF, denominatorDF, f,
                Distributions.upperF(f, Double(numeratorDF), Double(denominatorDF)))
    }

    struct Regression: Sendable {
        struct Term: Sendable {
            let name: String
            let estimate: Double
            let standardError: Double
            /// Nil for the intercept, which has no predictor to standardize by.
            let standardized: Double?
            let t: Double
            let p: Double
            let lowerBound: Double
            let upperBound: Double
            /// Variance inflation, reported only when there is more than one
            /// predictor for a predictor to be inflated by.
            let varianceInflation: Double?
        }

        let terms: [Term]
        let observations: Int
        let rSquared: Double
        let adjustedRSquared: Double
        let residualStandardError: Double
        let regressionSumOfSquares: Double
        let residualSumOfSquares: Double
        let numeratorDF: Int
        let denominatorDF: Int
        let f: Double
        let p: Double
    }

    /// OLS with an intercept. `predictors` are already complete-case aligned
    /// with `outcome`; the caller owns that decision because it is the one that
    /// has rows to report dropping.
    static func regression(outcome: [Double], predictors: [[Double]], names: [String]) -> Regression? {
        let observations = outcome.count
        let terms = predictors.count + 1
        guard !predictors.isEmpty, observations > terms,
              predictors.allSatisfy({ $0.count == observations }) else { return nil }

        let design = [Double](repeating: 1, count: observations) + predictors.flatMap { $0 }
        guard let fit = LeastSquares.solve(design: design, observations: observations,
                                           terms: terms, outcome: outcome) else { return nil }

        let mean = outcome.reduce(0, +) / Double(observations)
        var residualSumOfSquares = 0.0
        for row in 0..<observations {
            var fitted = fit.coefficients[0]
            for (index, predictor) in predictors.enumerated() {
                fitted += fit.coefficients[index + 1] * predictor[row]
            }
            let residual = outcome[row] - fitted
            residualSumOfSquares += residual * residual
        }
        let totalSumOfSquares = outcome.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
        guard totalSumOfSquares > 0 else { return nil }
        let regressionSumOfSquares = totalSumOfSquares - residualSumOfSquares
        let denominatorDF = observations - terms
        let numeratorDF = terms - 1
        let residualVariance = residualSumOfSquares / Double(denominatorDF)
        let critical = Distributions.inverseT(0.975, df: Double(denominatorDF))

        let outcomeDeviation = Self.standardDeviation(outcome, mean: mean)
        let inflations = Self.varianceInflations(predictors)

        var built: [Regression.Term] = []
        for index in 0..<terms {
            let estimate = fit.coefficients[index]
            let standardError = (residualVariance * fit.covariance[index][index]).squareRoot()
            let t = standardError > 0 ? estimate / standardError : Double.nan
            var standardized: Double?
            if index > 0, let outcomeDeviation, outcomeDeviation > 0 {
                let predictor = predictors[index - 1]
                let predictorMean = predictor.reduce(0, +) / Double(observations)
                if let deviation = Self.standardDeviation(predictor, mean: predictorMean) {
                    standardized = estimate * deviation / outcomeDeviation
                }
            }
            built.append(Regression.Term(
                name: index == 0 ? "(Intercept)" : names[index - 1],
                estimate: estimate,
                standardError: standardError,
                standardized: standardized,
                t: t,
                p: Distributions.twoTailedT(t, df: Double(denominatorDF)),
                lowerBound: estimate - critical * standardError,
                upperBound: estimate + critical * standardError,
                varianceInflation: index == 0 ? nil : inflations?[index - 1]
            ))
        }

        let f = (regressionSumOfSquares / Double(numeratorDF)) / residualVariance
        return Regression(
            terms: built, observations: observations,
            rSquared: regressionSumOfSquares / totalSumOfSquares,
            adjustedRSquared: 1 - (residualSumOfSquares / Double(denominatorDF))
                / (totalSumOfSquares / Double(observations - 1)),
            residualStandardError: residualVariance.squareRoot(),
            regressionSumOfSquares: regressionSumOfSquares,
            residualSumOfSquares: residualSumOfSquares,
            numeratorDF: numeratorDF, denominatorDF: denominatorDF,
            f: f, p: Distributions.upperF(f, Double(numeratorDF), Double(denominatorDF))
        )
    }

    /// Each predictor regressed on the others: `VIF = 1 / (1 - R²)`. Reusing the
    /// same solver means a predictor that is a combination of the others is
    /// refused here for the same reason it would be in the main fit.
    private static func varianceInflations(_ predictors: [[Double]]) -> [Double]? {
        guard predictors.count >= 2 else { return nil }
        let observations = predictors[0].count
        guard observations > predictors.count else { return nil }
        var inflations: [Double] = []
        for index in predictors.indices {
            let others = predictors.enumerated().filter { $0.offset != index }.map(\.element)
            let target = predictors[index]
            let mean = target.reduce(0, +) / Double(observations)
            let total = target.reduce(0) { $0 + ($1 - mean) * ($1 - mean) }
            guard total > 0,
                  let fit = LeastSquares.solve(
                    design: [Double](repeating: 1, count: observations) + others.flatMap { $0 },
                    observations: observations, terms: others.count + 1, outcome: target)
            else { return nil }
            var residual = 0.0
            for row in 0..<observations {
                var fitted = fit.coefficients[0]
                for (position, other) in others.enumerated() {
                    fitted += fit.coefficients[position + 1] * other[row]
                }
                residual += (target[row] - fitted) * (target[row] - fitted)
            }
            let explained = 1 - residual / total
            inflations.append(explained < 1 ? 1 / (1 - explained) : .infinity)
        }
        return inflations
    }

    struct CorrelationTest: Sendable {
        let t: Double
        let degreesOfFreedom: Int
        let p: Double
        let lowerBound: Double?
        let upperBound: Double?
    }

    /// The two-sided test of H₀: ρ = 0, with a Fisher z confidence interval.
    ///
    /// Spearman has no exact small-sample test here: it borrows Pearson's t
    /// approximation, and its interval uses the Bonett–Wright standard error,
    /// which widens the Fisher interval to account for ranking. Both are
    /// asymptotic, and the result's caption says so.
    static func test(_ coefficient: Double, count: Int, method: CorrelationMethod) -> CorrelationTest? {
        let degreesOfFreedom = count - 2
        guard degreesOfFreedom >= 1, abs(coefficient) < 1 else { return nil }
        let t = coefficient * (Double(degreesOfFreedom) / (1 - coefficient * coefficient)).squareRoot()
        let p = Distributions.twoTailedT(t, df: Double(degreesOfFreedom))
        guard count > 3 else {
            return CorrelationTest(t: t, degreesOfFreedom: degreesOfFreedom, p: p,
                                   lowerBound: nil, upperBound: nil)
        }
        let standardError = method == .pearson
            ? (1 / Double(count - 3)).squareRoot()
            : (1.06 / Double(count - 3)).squareRoot()
        let z = atanh(coefficient)
        let half = 1.959963984540054 * standardError
        return CorrelationTest(t: t, degreesOfFreedom: degreesOfFreedom, p: p,
                               lowerBound: tanh(z - half), upperBound: tanh(z + half))
    }

    /// Nil when there are fewer than two pairs or either variable is constant,
    /// which is undefined rather than zero.
    static func correlation(_ left: [Double], _ right: [Double], method: CorrelationMethod) -> Double? {
        guard left.count == right.count, left.count >= 2 else { return nil }
        switch method {
        case .pearson: return Self.pearson(left, right)
        case .spearman: return Self.pearson(Self.ranks(left), Self.ranks(right))
        }
    }

    private static func pearson(_ left: [Double], _ right: [Double]) -> Double? {
        let count = Double(left.count)
        let leftMean = left.reduce(0, +) / count
        let rightMean = right.reduce(0, +) / count
        var covariance = 0.0, leftSum = 0.0, rightSum = 0.0
        for index in left.indices {
            let a = left[index] - leftMean
            let b = right[index] - rightMean
            covariance += a * b
            leftSum += a * a
            rightSum += b * b
        }
        let denominator = (leftSum * rightSum).squareRoot()
        guard denominator > 0 else { return nil }
        return max(-1, min(1, covariance / denominator))
    }

    /// Ranks with ties averaged, which is what makes Spearman a Pearson on ranks.
    static func ranks(_ values: [Double]) -> [Double] {
        let order = values.indices.sorted { values[$0] < values[$1] }
        var ranks = [Double](repeating: 0, count: values.count)
        var index = 0
        while index < order.count {
            var end = index
            while end + 1 < order.count, values[order[end + 1]] == values[order[index]] { end += 1 }
            let average = Double(index + end) / 2 + 1
            for position in index...end { ranks[order[position]] = average }
            index = end + 1
        }
        return ranks
    }
}
