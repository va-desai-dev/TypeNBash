import CryptoKit
import Foundation

/// An immutable input for analysis work, captured only when an action requests it.
nonisolated struct CSVAnalysisSnapshot: Sendable {
    enum Scope: String, CaseIterable, Identifiable, Codable, Sendable {
        case allRows, visibleRows

        var id: String { self.rawValue }
        var label: String { self == .allRows ? "All rows" : "Filtered rows" }
    }

    let table: CSVTable
    /// Zero-based record indices in the source, even when rows are sorted or filtered.
    let sourceRows: [Int]
    let columnTypes: [Int: CSVArrangement.VariableFlag]

    /// A column read as numbers.
    ///
    /// `values` stays the length and order of the snapshot so a caller can pair
    /// two columns by position. Missing and unusable cells are both `nil` there
    /// but counted apart, because dropping a blank and dropping `12kg` are not
    /// the same event to report.
    struct NumericColumn: Sendable {
        let values: [Double?]
        let missingRows: [Int]
        let invalidRows: [Int]
    }

    /// A column read as levels, for frequencies and cross-tabulation.
    struct TextColumn: Sendable {
        let values: [String?]
        let missingRows: [Int]
    }

    func numericColumn(at index: Int, missingCodes: Set<String> = []) throws -> NumericColumn {
        guard self.table.columns.indices.contains(index) else { throw CSVAnalysisError.invalidColumn }
        var values: [Double?] = []
        var missing: [Int] = []
        var invalid: [Int] = []
        values.reserveCapacity(self.table.rows.count)
        for (rowIndex, row) in self.table.rows.enumerated() {
            let text = (row.indices.contains(index) ? row[index] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || missingCodes.contains(text) {
                missing.append(self.sourceRows[rowIndex])
                values.append(nil)
            } else if let value = Double(text), value.isFinite {
                values.append(value)
            } else {
                invalid.append(self.sourceRows[rowIndex])
                values.append(nil)
            }
        }
        return NumericColumn(values: values, missingRows: missing, invalidRows: invalid)
    }

    func textColumn(at index: Int, missingCodes: Set<String> = []) throws -> TextColumn {
        guard self.table.columns.indices.contains(index) else { throw CSVAnalysisError.invalidColumn }
        var values: [String?] = []
        var missing: [Int] = []
        values.reserveCapacity(self.table.rows.count)
        for (rowIndex, row) in self.table.rows.enumerated() {
            let text = (row.indices.contains(index) ? row[index] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || missingCodes.contains(text) {
                missing.append(self.sourceRows[rowIndex])
                values.append(nil)
            } else {
                values.append(text)
            }
        }
        return TextColumn(values: values, missingRows: missing)
    }

    /// The header now at a step's recorded position, or nil when the table has
    /// since lost that column.
    func header(at index: Int) -> String? {
        self.table.columns.indices.contains(index) ? self.table.columns[index] : nil
    }

    var csvText: String { CSVEngine.generate(from: self.table) }

    /// Identifies these exact cells. Two captures with the same fingerprint
    /// produce the same numbers, which is what lets a result say it is stale.
    var fingerprint: String {
        SHA256.hash(data: Data(self.csvText.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    func inputSummary(dataset: String, scope: Scope) -> AnalysisInputSummary {
        AnalysisInputSummary(
            dataset: dataset,
            scope: scope,
            rowCount: self.table.rows.count,
            columnCount: self.table.columns.count,
            fingerprint: self.fingerprint,
            capturedAt: Date()
        )
    }
}

nonisolated enum CSVAnalysisError: LocalizedError {
    case noTable, invalidColumn
    /// The step itself does not describe a runnable analysis, whatever the data says.
    case invalidStep(String)
    case missingValues(String)
    case notEnoughData(String)
    case datasetUnavailable(String)
    case tooManyLevels(String)
    case unsupportedNotebook(String)

    var errorDescription: String? {
        switch self {
        case .noTable: "No CSV table is open."
        case .invalidColumn: "The requested CSV column does not exist."
        case .invalidStep(let message): message
        case .missingValues(let message): message
        case .notEnoughData(let message): message
        case .datasetUnavailable(let message): message
        case .tooManyLevels(let message): message
        case .unsupportedNotebook(let message): message
        }
    }
}
