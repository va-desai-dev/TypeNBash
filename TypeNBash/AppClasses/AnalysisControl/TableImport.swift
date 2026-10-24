//
//  Item.swift
//  DFeZY
//
//  Created by Vedant A. Desai on 9/13/26.
//

import Foundation
import SwiftData
import SwiftUI
import Observation
import UniformTypeIdentifiers

/// A parsed CSV as a value.
///
/// `CSVStorage` below is a mutable class the grid edits in place, which is what
/// the grid wants and exactly what a file preview cannot be:
/// `FileBrowserModel.makePreview` parses off the main actor and its
/// `FilePreview` has to be `Sendable`. So the model carries one of these and
/// the view turns it into storage. `nonisolated` for the same reason
/// `WorkspaceFileEntry` is — the target's default isolation is `MainActor`.
nonisolated struct CSVTable: Sendable {
    var columns: [String] = []
    var rows: [[String]] = []

    /// No columns means there was no header row to read, so nothing to table.
    var isEmpty: Bool { self.columns.isEmpty }
}

/// Flat, unobserved memory footprint designed to handle millions of cells instantly
final class CSVStorage {
    /// Analysis hints for this open table; CSV itself has no type metadata.
    var columnTypes: [Int: CSVArrangement.VariableFlag] = [:]
    var columns: [String] = []
    var rows: [[String]] = []

    static let empty = CSVStorage()

    init() { }

    init(_ table: CSVTable) {
        self.columns = table.columns
        self.rows = table.rows
    }

    /// A snapshot of the current cells, to hand back to a model or write to disk.
    var table: CSVTable {
        CSVTable(columns: self.columns, rows: self.rows)
    }

    func clear() {
        columns.removeAll()
        rows.removeAll()
        columnTypes.removeAll()
    }
}

/// A view-only sort + filter over a `CSVStorage`, the way Numbers' column menu
/// works: the rules reorder and hide rows for display and never touch the
/// file's record order, so arranging a table doesn't dirty the document.
///
/// `visibleRows` is the indirection the grid draws through — display row *n* is
/// `storage.rows[visibleRows[n]]`. Everything that used to index `rows` by a
/// screen position has to go through it, or a sorted edit lands on the wrong
/// record.
final class CSVArrangement {

    enum Direction: Hashable {
        case ascending, descending
    }

    nonisolated enum VariableFlag: String, CaseIterable, Identifiable, Sendable {
        case logical = "Logical"
        case character = "Character"
        case double = "Double"
        case integer = "Integer"
        case numeric = "Numeric"
        case datetime = "DateTime"
        case date = "Date"
        case time = "Time"
        case factor = "Factor"
        case skip = "Skip"
        var id: String { self.rawValue }
    }
    /// Numbers' filter conditions. The two emptiness tests take no operand,
    /// which is what `needsValue` drives in the popover.
    enum Condition: String, CaseIterable, Identifiable {
        case contains = "contains"
        case doesNotContain = "does not contain"
        case equals = "is"
        case doesNotEqual = "is not"
        case beginsWith = "begins with"
        case endsWith = "ends with"
        case isEmpty = "is empty"
        case isNotEmpty = "is not empty"

        var id: String { self.rawValue }
        var needsValue: Bool { self != .isEmpty && self != .isNotEmpty }

        func matches(_ field: String, _ value: String) -> Bool {
            switch self {
            case .contains: field.localizedCaseInsensitiveContains(value)
            case .doesNotContain: !field.localizedCaseInsensitiveContains(value)
            case .equals: field.caseInsensitiveCompare(value) == .orderedSame
            case .doesNotEqual: field.caseInsensitiveCompare(value) != .orderedSame
            case .beginsWith: field.lowercased().hasPrefix(value.lowercased())
            case .endsWith: field.lowercased().hasSuffix(value.lowercased())
            case .isEmpty: field.isEmpty
            case .isNotEmpty: !field.isEmpty
            }
        }
    }

    struct Filter: Equatable {
        var condition: Condition = .contains
        var value: String = ""

        /// `contains ""` matches every row, so treat a half-typed rule as no
        /// rule rather than blanking the table while the user types.
        var isActive: Bool { !self.condition.needsValue || !self.value.isEmpty }
    }

    /// Shared identity arrangement, for a grid with no container attached yet.
    static let identity = CSVArrangement()

    var sortColumn: Int?
    var sortDirection: Direction = .ascending
    var filters: [Int: Filter] = [:]

    /// Display row → storage row.
    private(set) var visibleRows: [Int] = []

    var rowCount: Int { self.visibleRows.count }

    /// The storage row behind a display row, or nil past the end.
    func storageRow(_ displayRow: Int) -> Int? {
        self.visibleRows.indices.contains(displayRow) ? self.visibleRows[displayRow] : nil
    }

    func isSorted(_ column: Int) -> Bool { self.sortColumn == column }

    func isFiltered(_ column: Int) -> Bool { self.filters[column]?.isActive == true }

    /// Whether a column's rules decide what shows or in what order — an edit to
    /// such a column has to rebuild, since the row may now belong elsewhere.
    func affectsArrangement(column: Int) -> Bool {
        self.sortColumn == column || self.isFiltered(column)
    }

    /// Recomputes `visibleRows`: O(rows) filtering, O(rows log rows) sorting.
    /// Cheap enough to run on every rule change and after edits to a ruled
    /// column, which is the only thing that keeps the mapping honest.
    func rebuild(from storage: CSVStorage) {
        let active = self.filters
            .filter(\.value.isActive)
            .map { (column: $0.key, filter: $0.value) }

        var indices: [Int]
        if active.isEmpty {
            indices = Array(storage.rows.indices)
        } else {
            indices = storage.rows.indices.filter { row in
                active.allSatisfy {
                    $0.filter.condition.matches(Self.field(storage, row, $0.column), $0.filter.value)
                }
            }
        }

        if let column = self.sortColumn {
            let ascending = self.sortDirection == .ascending
            indices.sort { lhs, rhs in
                let left = Self.field(storage, lhs, column)
                let right = Self.field(storage, rhs, column)
                // Blanks sink to the bottom in both directions, like a spreadsheet.
                if left.isEmpty != right.isEmpty { return right.isEmpty }
                let order = Self.compare(left, right)
                // Swift's sort isn't stable; tie-break on file position so equal
                // keys keep their original order.
                if order == .orderedSame { return lhs < rhs }
                return ascending ? order == .orderedAscending : order == .orderedDescending
            }
        }

        self.visibleRows = indices
    }

    /// Short rows are legal CSV, so a missing cell reads as empty.
    private static func field(_ storage: CSVStorage, _ row: Int, _ column: Int) -> String {
        let cells = storage.rows[row]
        return column < cells.count ? cells[column] : ""
    }

    /// Numeric when both sides parse as numbers, so "10" sorts after "9" rather
    /// than between "1" and "2"; otherwise a localized compare, which still
    /// orders embedded digits sensibly.
    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if let left = Double(lhs), let right = Double(rhs) {
            if left == right { return .orderedSame }
            return left < right ? .orderedAscending : .orderedDescending
        }
        return lhs.localizedStandardCompare(rhs)
    }
}

struct CSVTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.commaSeparatedText] }
    var text: String

    init(text: String = "") { self.text = text }

    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents {
            self.text = String(data: data, encoding: .utf8) ?? ""
        } else {
            self.text = ""
        }
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = text.data(using: .utf8) ?? Data()
        return FileWrapper(regularFileWithContents: data)
    }
}

struct CSVEngine {

    /// Parses into a value, so a preview can be built off the main actor.
    nonisolated static func parse(_ text: String) -> CSVTable {
        var parsedRows: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var insideQuotes = false

        var iterator = text.makeIterator()
        var next = iterator.next()
        var hasRecord = false
        while let char = next {
            next = iterator.next()
            hasRecord = true
            if insideQuotes {
                if char == "\"" {
                    if next == "\"" {
                        currentField.append("\"")
                        next = iterator.next()
                    } else {
                        insideQuotes = false
                    }
                } else {
                    currentField.append(char)
                }
            } else {
                switch char {
                case "\"":
                    insideQuotes = true
                case ",":
                    currentRow.append(currentField)
                    currentField = ""
                case "\n", "\r", "\r\n":
                    currentRow.append(currentField)
                    parsedRows.append(currentRow)
                    currentField = ""
                    currentRow = []
                    hasRecord = false
                default:
                    currentField.append(char)
                }
            }
        }

        if hasRecord {
            currentRow.append(currentField)
            parsedRows.append(currentRow)
        }

        guard let firstRow = parsedRows.first else { return CSVTable() }
        return CSVTable(columns: firstRow, rows: Array(parsedRows.dropFirst()))
    }

    static func parse(_ text: String, into storage: CSVStorage) {
        storage.clear()
        let table = Self.parse(text)
        storage.columns = table.columns
        storage.rows = table.rows
    }

    nonisolated static func generate(from table: CSVTable) -> String {
        var output = ""
        let escapedHeaders = table.columns.map { escapeField($0) }.joined(separator: ",")
        output.append(escapedHeaders + "\n")

        for row in table.rows {
            let escapedCells = row.map { escapeField($0) }.joined(separator: ",")
            output.append(escapedCells + "\n")
        }
        return output
    }

    static func generate(from storage: CSVStorage) -> String {
        Self.generate(from: storage.table)
    }

    nonisolated private static func escapeField(_ field: String) -> String {
        if field.contains(",") || field.contains("\"") || field.contains(where: \.isNewline) {
            let sanitized = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(sanitized)\""
        }
        return field
    }
}
