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
        let cleanText = text.replacingOccurrences(of: "\r\n", with: "\n")
        var parsedRows: [[String]] = []
        var currentField = ""
        var currentRow: [String] = []
        var insideQuotes = false

        var iterator = cleanText.makeIterator()
        while let char = iterator.next() {
            if insideQuotes {
                if char == "\"" {
                    insideQuotes = false
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
                case "\n":
                    currentRow.append(currentField)
                    parsedRows.append(currentRow)
                    currentField = ""
                    currentRow = []
                default:
                    currentField.append(char)
                }
            }
        }

        if !currentField.isEmpty || !currentRow.isEmpty {
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
        if field.contains(",") || field.contains("\"") || field.contains("\n") {
            let sanitized = field.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(sanitized)\""
        }
        return field
    }
}
