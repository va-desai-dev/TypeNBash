import Foundation

/// An immutable input for analysis work, captured only when an action requests it.
nonisolated struct CSVAnalysisSnapshot: Sendable {
    enum Scope: Sendable { case allRows, visibleRows }

    let table: CSVTable
    /// Zero-based record indices in the source, even when rows are sorted or filtered.
    let sourceRows: [Int]
    let columnTypes: [Int: CSVArrangement.VariableFlag]

    struct NumericColumn: Sendable {
        /// Same length and row order as the snapshot. Missing/invalid cells stay nil.
        let values: [Double?]
        let missingRows: [Int]
        let invalidRows: [Int]
    }

    func numericColumn(at index: Int) throws -> NumericColumn {
        guard table.columns.indices.contains(index) else { throw CSVAnalysisError.invalidColumn }
        var values: [Double?] = []
        var missing: [Int] = []
        var invalid: [Int] = []
        values.reserveCapacity(table.rows.count)
        for (rowIndex, row) in table.rows.enumerated() {
            let text = (row.indices.contains(index) ? row[index] : "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty {
                missing.append(sourceRows[rowIndex])
                values.append(nil)
            } else if let value = Double(text), value.isFinite {
                values.append(value)
            } else {
                invalid.append(sourceRows[rowIndex])
                values.append(nil)
            }
        }
        return NumericColumn(values: values, missingRows: missing, invalidRows: invalid)
    }

    var csvText: String { CSVEngine.generate(from: table) }
}

nonisolated enum CSVAnalysisError: LocalizedError {
    case noTable, invalidColumn

    var errorDescription: String? {
        switch self {
        case .noTable: "No CSV table is open."
        case .invalidColumn: "The requested CSV column does not exist."
        }
    }
}
