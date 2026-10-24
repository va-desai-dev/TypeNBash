import Foundation

/// Turns results into text — on screen and in an exported file alike, so a
/// number never reads one way in the pane and another in the report.
nonisolated enum NotebookReport {

    static func text(_ cell: AnalysisCell) -> String {
        switch cell {
        case .text(let value): value
        case .count(let value): value.formatted(.number)
        case .missing: "—"
        case .probability(let value):
            if value.isNaN {
                "—"
            } else if value < 0.001 {
                "< .001"
            } else {
                String(format: "%.3f", value).replacingOccurrences(
                    of: "0.", with: ".", options: [.anchored])
            }
        case .number(let value):
            if value == value.rounded(), abs(value) < 1e15 {
                String(Int(value))
            } else if abs(value) >= 0.001, abs(value) < 1e7 {
                String(format: "%.4f", value)
            } else {
                String(format: "%.4g", value)
            }
        }
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
                output += "| " + table.columns.joined(separator: " | ") + " |\n"
                output += "| " + table.columns.map { _ in "---" }.joined(separator: " | ") + " |\n"
                for row in table.rows {
                    output += "| " + row.map(Self.text).joined(separator: " | ") + " |\n"
                }
            }
        }
        return output
    }
}
