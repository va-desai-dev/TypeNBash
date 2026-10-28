import Foundation

/// Turns results into text — on screen and in an exported file alike, so a
/// number never reads one way in the pane and another in the report.
nonisolated enum NotebookReport {

    static func text(_ cell: AnalysisCell) -> String {
        switch cell {
        case .text(let value): value
        case .count(let value): value.formatted(.number)
        case .missing: "—"
        case .probability(let value, let starred):
            if value.isNaN {
                "—"
            } else if value < 0.001 {
                "< .001" + (starred ? Self.stars(value) : "")
            } else {
                String(format: "%.3f", value).replacingOccurrences(
                    of: "0.", with: ".", options: [.anchored]) + (starred ? Self.stars(value) : "")
            }
        case .number(let value):
            Self.number(value)
        case .estimate(let value, let p):
            Self.number(value) + Self.stars(p)
        }
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded(), abs(value) < 1e15 {
            String(Int(value))
        } else if abs(value) >= 0.001, abs(value) < 1e7 {
            String(format: "%.4f", value)
        } else {
            String(format: "%.4g", value)
        }
    }

    /// The conventional thresholds. An undefined p earns none rather than
    /// passing for significant.
    static func stars(_ p: Double) -> String {
        guard !p.isNaN else { return "" }
        return p < 0.001 ? "***" : p < 0.01 ? "**" : p < 0.05 ? "*" : ""
    }

    static let starLegend = "* p < .05, ** p < .01, *** p < .001"

    /// Shown under a table only when a star is actually on it.
    static func legend(for table: AnalysisResultTable) -> String? {
        table.rows.contains { $0.contains(where: \.isStarred) } ? Self.starLegend : nil
    }

    /// A pipe would end the cell and a star could pair into emphasis.
    private static func markdownCell(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    static func markdown(
        steps: [AnalysisStep],
        results: [UUID: AnalysisResult],
        failures: [UUID: String],
        missingCodes: [String]
    ) -> String {
        var output = "# Analysis notebook\n\n"
        output += "Exported \(Date().formatted(date: .abbreviated, time: .shortened)).\n"
        output += missingCodes.isEmpty
            ? "Blank cells count as missing; nothing else does.\n"
            : "Missing codes: \(missingCodes.map { "`\($0)`" }.joined(separator: ", ")).\n"

        for (position, step) in steps.enumerated() {
            output += "\n## \(position + 1). \(step.title)\n\n"
            if let failure = failures[step.id] {
                output += "> Did not run: \(failure)\n"
                continue
            }
            guard let result = results[step.id] else {
                output += "> Not run.\n"
                continue
            }
            let input = result.input
            output += "*\(input.datasetLabel) · \(input.scope.label) · \(input.rowCount) rows · "
            output += "\(step.missing.rawValue) · capture `\(input.fingerprint)` at "
            output += "\(input.capturedAt.formatted(date: .omitted, time: .standard))*\n"
            for note in result.notes { output += "\n- \(note)\n" }
            for table in result.tables {
                output += "\n"
                if let caption = table.caption { output += "\(caption)\n\n" }
                output += "| " + table.columns.map(Self.markdownCell).joined(separator: " | ") + " |\n"
                output += "| " + table.columns.map { _ in "---" }.joined(separator: " | ") + " |\n"
                for row in table.rows {
                    output += "| " + row.map { Self.markdownCell(Self.text($0)) }.joined(separator: " | ") + " |\n"
                }
                if Self.legend(for: table) != nil {
                    output += "\n\\* *p* < .05, \\*\\* *p* < .01, \\*\\*\\* *p* < .001\n"
                }
            }
        }
        return output
    }
}
