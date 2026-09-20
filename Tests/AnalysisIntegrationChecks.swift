import AppKit
import Foundation
import SwiftUI
@testable import TypeNBash

/// Checks the notebook's statistics against values a user would get from R, and
/// the step/document values against round-tripping and validation.
@main
struct AnalysisIntegrationChecks {
    @MainActor static func main() async throws {

        // MARK: Descriptives

        let sequence = snapshot(columns: ["x"], rows: (1...10).map { [String($0)] })
        let describeStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "x")]))
        let described = try AnalysisKernel.run(describeStep, on: sequence)
        let summary = described.tables[0].rows[0]
        check(summary[1] == .count(10), "Descriptives count every usable row")
        check(near(summary[4], 5.5), "Mean of 1...10 is 5.5")
        check(near(summary[5], 3.0276503541), "Sample SD uses n-1, matching R's sd()")
        check(near(summary[7], 3.25) && near(summary[8], 5.5) && near(summary[9], 7.75),
              "Quartiles interpolate like R's default quantile type 7")

        // MARK: Missing versus unusable

        let mixed = snapshot(columns: ["v"], rows: [["1"], [""], ["NA"], ["12kg"], ["4"]])
        let mixedStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "v")]))
        let untyped = try AnalysisKernel.run(mixedStep, on: mixed, missingCodes: []).tables[0].rows[0]
        check(untyped[2] == .count(1) && untyped[3] == .count(2),
              "Without a declared code, only blanks are missing and NA counts as unusable")
        let declared = try AnalysisKernel.run(mixedStep, on: mixed, missingCodes: ["NA"]).tables[0].rows[0]
        check(declared[2] == .count(2) && declared[3] == .count(1),
              "A declared NA code moves those cells from unusable to missing")
        check(near(declared[4], 2.5), "The mean ignores both missing and unusable cells")

        // MARK: Missing policy

        let paired = snapshot(columns: ["a", "b"], rows: [["1", "1"], ["2", "2"], ["", "3"], ["4", "4"]])
        let references = [ColumnReference(index: 0, name: "a"), ColumnReference(index: 1, name: "b")]
        let pairwise = try AnalysisKernel.run(
            AnalysisStep(missing: .pairwise, operation: .describe(columns: references)), on: paired)
        check(pairwise.tables[0].rows[0][1] == .count(3) && pairwise.tables[0].rows[1][1] == .count(4),
              "Pairwise lets each column keep the rows it has")
        let listwise = try AnalysisKernel.run(
            AnalysisStep(missing: .listwise, operation: .describe(columns: references)), on: paired)
        check(listwise.tables[0].rows[0][1] == .count(3) && listwise.tables[0].rows[1][1] == .count(3),
              "Listwise drops the incomplete row from every column in the step")
        check(listwise.notes.contains { $0.contains("1 of 4 rows dropped") },
              "Listwise reports how many rows it dropped")
        var failed = false
        do { _ = try AnalysisKernel.run(
            AnalysisStep(missing: .fail, operation: .describe(columns: references)), on: paired) }
        catch { failed = true }
        check(failed, "The fail policy refuses a step rather than dropping a row")

        // MARK: Correlation

        let bivariate = snapshot(columns: ["x", "y"],
                                 rows: [["1", "2"], ["2", "4"], ["3", "5"], ["4", "4"], ["5", "5"]])
        let pearson = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .pearson)), on: bivariate)
        check(near(pearson.tables[0].rows[0][2], 0.7745966692), "Pearson r matches R's cor()")
        check(pearson.tables[0].rows[0][1] == .number(1), "The diagonal is 1")
        check(pearson.tables[1].rows[0][2] == .count(5), "The tests table reports complete pairs")
        let spearman = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .spearman)), on: bivariate)
        check(near(spearman.tables[0].rows[0][2], 0.7378647874),
              "Spearman averages tied ranks, matching R's cor(method = \"spearman\")")

        let constant = snapshot(columns: ["x", "y"], rows: [["1", "3"], ["2", "3"], ["3", "3"]])
        let flat = try AnalysisKernel.run(
            AnalysisStep(operation: .correlation(columns: references, method: .pearson)), on: constant)
        check(flat.tables[0].rows[0][2] == .missing, "A variable with no spread gives no coefficient")
        check(flat.notes.contains { $0.contains("no spread") }, "And says why")

        // MARK: Frequencies and cross-tabulation

        let factor = snapshot(columns: ["g", "h"],
                              rows: [["a", "x"], ["a", "y"], ["b", "x"], ["", "x"], ["b", "y"]])
        let frequency = try AnalysisKernel.run(
            AnalysisStep(operation: .frequency(column: ColumnReference(index: 0, name: "g"))), on: factor)
        check(frequency.tables[0].rows.count == 2, "Frequencies list the levels present, not the blanks")
        check(frequency.tables[0].rows[0][1] == .count(2) && near(frequency.tables[0].rows[0][2], 50),
              "Percentages are of the non-missing rows")
        check(frequency.tables[0].rows.last.map { near($0[3], 100) } == true, "Cumulative percent reaches 100")

        let crossTab = try AnalysisKernel.run(
            AnalysisStep(operation: .crossTabulation(rows: ColumnReference(index: 0, name: "g"),
                                                     columns: ColumnReference(index: 1, name: "h"))), on: factor)
        let body = crossTab.tables[0].rows
        check(body.count == 3 && body[2][0] == .text("Total"), "A cross-tab ends in a totals row")
        check(body[0][1] == .count(1) && body[0][3] == .count(2), "Cell and row totals count correctly")
        check(body[2][3] == .count(4), "The grand total excludes the row missing a variable")
        check(crossTab.notes.contains { $0.contains("1 of 5") }, "And that exclusion is reported")

        // MARK: Provenance and drift

        let renamed = snapshot(columns: ["years"], rows: [["1"], ["2"]])
        let agedStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 0, name: "age")]))
        let drifted = try AnalysisKernel.run(agedStep, on: renamed)
        check(drifted.notes.contains { $0.contains("years") && $0.contains("age") },
              "A step reports a header that moved instead of quietly using the new column")
        var absent = false
        do { _ = try AnalysisKernel.run(
            AnalysisStep(operation: .describe(columns: [ColumnReference(index: 4, name: "gone")])), on: renamed) }
        catch { absent = true }
        check(absent, "A step whose column no longer exists fails loudly")

        check(sequence.fingerprint == snapshot(columns: ["x"], rows: (1...10).map { [String($0)] }).fingerprint,
              "Identical tables fingerprint identically")
        check(sequence.fingerprint != mixed.fingerprint, "Different tables do not")
        check(described.input.rowCount == 10 && described.input.scope == .allRows,
              "A result carries the shape of the table it was computed from")

        // MARK: The notebook document

        let notebook = AnalysisNotebookFile(missingCodes: ["NA"], steps: [describeStep, agedStep])
        let encoded = try JSONEncoder().encode(notebook)
        let decoded = try JSONDecoder().decode(AnalysisNotebookFile.self, from: encoded)
        check(decoded == notebook, "Steps and missing codes round-trip through the sidecar format")
        try decoded.validate()
        var rejected = 0
        for bad in [AnalysisNotebookFile(version: 2),
                    AnalysisNotebookFile(steps: [AnalysisStep(dataset: "../secrets.csv", operation: .describe(columns: []))]),
                    AnalysisNotebookFile(steps: [AnalysisStep(operation: .describe(columns: [ColumnReference(index: -1, name: "x")]))])] {
            do { try bad.validate() } catch { rejected += 1 }
        }
        check(rejected == 3, "A future version, an escaping path and a negative column are all refused")

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = LocalWorkspaceFileSystem()
        check(try await AnalysisNotebookFile.load(in: root, fileSystem: fileSystem) == nil,
              "A project with no notebook loads as no notebook, not an error")
        try await notebook.save(in: root, fileSystem: fileSystem)
        check(try await AnalysisNotebookFile.load(in: root, fileSystem: fileSystem) == notebook,
              "A saved notebook reloads from the project root")

        // MARK: The report

        let report = NotebookReport.markdown(steps: [describeStep], results: [describeStep.id: described],
                                             failures: [:], missingCodes: ["NA"])
        check(report.contains("| Variable | N |"), "The export writes result tables as Markdown")
        check(report.contains(described.input.fingerprint), "And records which capture produced them")
        check(NotebookReport.text(.missing) == "—" && NotebookReport.text(.count(1000)) == "1,000",
              "Cells format the same on screen and in the export")

        // MARK: The pane, end to end

        NSApplication.shared.setActivationPolicy(.accessory)
        try Data("g,v\na,1\nb,2\na,3\n".utf8).write(to: root.appendingPathComponent("sample.csv"))
        let session = WindowSession(localRoot: root)
        let model = NotebookModel(session: session, editor: EditorSession())
        let host = NSHostingView(rootView: NotebookView(model: model).frame(width: 900, height: 600))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        for _ in 0..<100 where !model.isLoaded {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        check(model.isLoaded, "The pane loads its notebook when it appears")
        check(model.availableDatasets == ["sample.csv"], "The project's CSV files are offered as datasets")
        check(model.steps.count == 2, "The notebook saved earlier in this run reloads its steps")
        check(model.capture == nil, "With no grid mounted there is no captured table")
        check(await model.headers(for: "sample.csv") == ["g", "v"],
              "Headers for a project file are read from disk for the step composer")

        check(AnalysisNotebookFile().missingCodes == ["NA"],
              "A new notebook treats NA as missing, and not N/A")

        model.missingCodes = []
        let fileStep = AnalysisStep(dataset: "sample.csv",
                                    operation: .frequency(column: ColumnReference(index: 0, name: "g")))
        await model.run(fileStep)
        check(model.failures[fileStep.id] == nil, "A step against a project file runs without the editor")
        check(model.results[fileStep.id]?.tables[0].rows.count == 2, "And produces its frequency table")
        check(model.results[fileStep.id]?.input.dataset == "sample.csv", "Recording which file it read")

        let openStep = AnalysisStep(operation: .describe(columns: [ColumnReference(index: 1, name: "v")]))
        await model.run(openStep)
        check(model.failures[openStep.id]?.contains("No CSV table was open") == true,
              "A step on the open table explains itself when nothing was captured")

        model.remove(fileStep.id)
        check(model.results[fileStep.id] == nil && model.hasUnsavedChanges,
              "Removing a step drops its result and dirties the notebook")
        host.layoutSubtreeIfNeeded()

        // MARK: Sending a cell to the console

        let snippetURL = root.appendingPathComponent("snippet.R")
        try Data("""
        # %% Setup
        x <- 1

        # %% 1. First
        mean(c(1, 2))

        # %% 2. Second
        sd(c(1, 2))

        """.utf8).write(to: snippetURL)
        let editorModel = FileBrowserModel()
        editorModel.select(WorkspaceFileEntry(url: snippetURL, isDirectory: false, byteCount: nil))
        let editorSession = EditorSession()
        let editorHost = NSHostingView(rootView: VStack(spacing: 0) {
            FileBrowserPaneHeader(model: editorModel, session: editorSession, onRunInConsole: { _ in })
            FileViewer(model: editorModel, session: editorSession)
        }.frame(width: 800, height: 400))
        let editorWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
                                    styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        editorWindow.isReleasedWhenClosed = false
        editorWindow.contentView = editorHost
        editorWindow.makeKeyAndOrderFront(nil)
        defer { editorWindow.close() }
        for _ in 0..<100 {
            editorHost.layoutSubtreeIfNeeded()
            if editorSession.textView?.string.contains("mean") == true { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        guard let scriptView = editorSession.textView else { fatalError("The script editor did not mount") }
        let scriptText = scriptView.string as NSString

        func caret(at needle: String, offset: Int = 2) {
            scriptView.setSelectedRange(NSRange(location: scriptText.range(of: needle).location + offset,
                                                length: 0))
        }
        caret(at: "mean(c(1, 2))")
        check(editorSession.consoleSnippet()?.trimmingCharacters(in: .whitespacesAndNewlines)
              == "mean(c(1, 2))",
              "With no selection, the caret's own cell is what goes to the console")
        caret(at: "# %% 2. Second", offset: 1)
        check(editorSession.consoleSnippet()?.trimmingCharacters(in: .whitespacesAndNewlines)
              == "sd(c(1, 2))",
              "A caret resting on a delimiter means the cell it introduces")
        caret(at: "x <- 1")
        check(editorSession.consoleSnippet()?.trimmingCharacters(in: .whitespacesAndNewlines) == "x <- 1",
              "The first cell needs no delimiter above it")
        scriptView.setSelectedRange(scriptText.range(of: "mean(c(1, 2))"))
        check(editorSession.consoleSnippet() == "mean(c(1, 2))",
              "A selection wins over the cell it sits in")

        // MARK: Changing the vocabulary re-runs what has already run

        try Data("v\na\n1\nNA\n2\n".utf8).write(to: root.appendingPathComponent("codes.csv"))
        let codesStep = AnalysisStep(dataset: "codes.csv",
                                     operation: .describe(columns: [ColumnReference(index: 0, name: "v")]))
        let neverRun = AnalysisStep(dataset: "codes.csv",
                                    operation: .frequency(column: ColumnReference(index: 0, name: "v")))
        try await AnalysisNotebookFile(missingCodes: [], steps: [codesStep, neverRun])
            .save(in: root, fileSystem: fileSystem)
        let reopened = NotebookModel(session: session, editor: EditorSession())
        await reopened.load()
        check(reopened.steps.count == 2 && reopened.missingCodes.isEmpty,
              "A saved notebook reopens with its own vocabulary, not the default")

        await reopened.run(codesStep)
        let before = reopened.results[codesStep.id]?.tables[0].rows[0]
        check(before?[2] == .count(0) && before?[3] == .count(2),
              "With no codes declared, the NA row is unusable and nothing is missing")

        reopened.missingCodes = ["NA"]
        for _ in 0..<100 where reopened.results[codesStep.id]?.tables[0].rows[0][2] == .count(0) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let after = reopened.results[codesStep.id]?.tables[0].rows[0]
        check(after?[2] == .count(1) && after?[3] == .count(1),
              "Declaring NA re-runs the step and moves that row from unusable to missing")
        check(reopened.results[neverRun.id] == nil && reopened.failures[neverRun.id] == nil,
              "A step that has never run is not started by a vocabulary change")

        // MARK: Significance
        //
        // Expected values are R's, via:
        //   pt / pchisq / pf, cor.test(x, y), chisq.test(m, correct = FALSE),
        //   p.adjust(p, "holm") and p.adjust(p, "BH").

        for (name, got, want) in [
            ("pnorm(1.96)", Distributions.normal(1.96), 0.97500210485177963),
            ("pnorm(-2.5)", Distributions.normal(-2.5), 0.0062096653257761349),
            ("pt(2, 10)", Distributions.studentT(2, df: 10), 0.96330598261462974),
            ("2*pt(-2, 10)", Distributions.twoTailedT(2, df: 10), 0.073388034770740393),
            ("2*pt(-3, 48)", Distributions.twoTailedT(3, df: 48), 0.0042716622441844616),
            ("2*pt(-12, 200)", Distributions.twoTailedT(12, df: 200), 2.4221360052465909e-25),
            ("pchisq(3.8414588, 1)", Distributions.chiSquare(3.841458820694124, df: 1), 0.95000000000000007),
            ("pchisq(18.31, 4, upper)", Distributions.upperChiSquare(18.31, df: 4), 0.0010732822472379843),
            ("pchisq(100, 10, upper)", Distributions.upperChiSquare(100, df: 10), 5.4497019829205302e-17),
            ("pf(4, 3, 20)", Distributions.fDistribution(4, 3, 20), 0.97792300033763757),
            ("pf(4, 3, 20, upper)", Distributions.upperF(4, 3, 20), 0.022076999662362429),
        ] {
            check(abs(got - want) <= abs(want) * 1e-12, "\(name) matches R to 12 significant digits")
        }
        check(Distributions.twoTailedT(12, df: 200) > 0,
              "A far-tail p keeps its digits instead of rounding to zero against 1")

        let holm = PValueAdjustment.holm.adjusted([0.004, 0.041, 0.13, 0.009])
        let hochberg = PValueAdjustment.benjaminiHochberg.adjusted([0.004, 0.041, 0.13, 0.009])
        check(zip(holm, [0.016, 0.082, 0.13, 0.027]).allSatisfy { abs($0 - $1) < 1e-12 },
              "Holm adjustment matches p.adjust(method = \"holm\")")
        check(zip(hochberg, [0.016, 0.0546666666666667, 0.13, 0.018]).allSatisfy { abs($0 - $1) < 1e-12 },
              "Benjamini–Hochberg matches p.adjust(method = \"BH\")")
        check(PValueAdjustment.none.adjusted([0.004, 0.041]) == [0.004, 0.041],
              "No adjustment leaves the raw values alone")

        let tested = try AnalysisKernel.run(
            AnalysisStep(adjustment: .none, operation: .correlation(columns: references, method: .pearson)),
            on: bivariate)
        let row = tested.tables[1].rows[0]
        check(row[4] == .count(3), "Correlation reports n - 2 degrees of freedom")
        check(near(row[5], 2.1213203435596428), "And the t statistic R's cor.test gives")
        guard case .probability(let correlationP) = row[6] else { fatalError("no p-value") }
        check(abs(correlationP - 0.12402706265755449) < 1e-12, "And its two-sided p-value")
        check(near(row[7], -0.34008203518750996) && near(row[8], 0.9842357551507267),
              "And the Fisher z interval cor.test reports")
        check(tested.tables[1].columns.count == 9, "With no adjustment there is no adjusted column")

        let adjustedRun = try AnalysisKernel.run(
            AnalysisStep(adjustment: .holm, operation: .correlation(
                columns: references + [ColumnReference(index: 0, name: "x")], method: .pearson)),
            on: bivariate)
        check(adjustedRun.tables[1].columns.contains("p (Holm)"),
              "A family of tests gains an adjusted column")
        check(adjustedRun.notes.contains { $0.contains("simultaneous tests") },
              "And says how many tests it adjusted for")

        let squared = try AnalysisKernel.run(
            AnalysisStep(operation: .crossTabulation(rows: ColumnReference(index: 0, name: "g"),
                                                     columns: ColumnReference(index: 1, name: "h"))),
            on: factor)
        check(squared.tables.count == 1,
              "A cross-tabulation describes the table and runs no test of its own")

        // Counts [[1, 1], [1, 2]], i.e. chisq.test(matrix(c(1,1,1,2), 2, byrow = TRUE)).
        let skewed = snapshot(columns: ["g", "h"],
                              rows: [["a", "x"], ["a", "y"], ["b", "x"], ["b", "y"], ["b", "y"]])
        let chiSquareStep = AnalysisStep(operation: .chiSquareIndependence(
            rows: ColumnReference(index: 0, name: "g"), columns: ColumnReference(index: 1, name: "h")))
        let chiSquareResult = try AnalysisKernel.run(chiSquareStep, on: skewed)
        let independence = chiSquareResult.tables[0].rows[0]
        check(chiSquareResult.tables.count == 2
              && chiSquareResult.tables[1].caption?.contains("Expected") == true,
              "The test is its own step, and reports the expected counts behind it")
        check(near(independence[0], 0.13888888888888881) && independence[1] == .count(1)
              && independence[2] == .count(5),
              "Chi-square, df and N match chisq.test(correct = FALSE)")
        guard case .probability(let independenceP) = independence[3] else { fatalError("no p-value") }
        check(abs(independenceP - 0.70938811501422649) < 1e-12, "As does its p-value")
        check(near(independence[4], 0.16666666666666663), "And Cramér's V follows from it")
        check(try AnalysisKernel.run(chiSquareStep, on: skewed).notes.contains { $0.contains("fewer than 5") },
              "A sparse table says the approximation is unreliable")
        var oneLevel = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .chiSquareIndependence(
                rows: ColumnReference(index: 0, name: "x"), columns: ColumnReference(index: 1, name: "y"))),
                on: snapshot(columns: ["x", "y"], rows: [["a", "p"], ["a", "p"]]))
        } catch { oneLevel = true }
        check(oneLevel, "A single-level variable fails rather than returning a degenerate test")

        // MARK: Comparing means
        //
        // Expected values are R's, via t.test(...) and summary(aov(y ~ f)).

        let scores = snapshot(columns: ["x", "g"], rows: [
            ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"],
            ["9", "b"], ["7", "b"], ["8", "b"], ["10", "b"],
        ])
        let outcome = ColumnReference(index: 0, name: "x")
        let grouping = ColumnReference(index: 1, name: "g")

        let oneSample = try AnalysisKernel.run(
            AnalysisStep(operation: .oneSampleT(column: outcome, testValue: 7)), on: scores).tables[0].rows[0]
        check(oneSample[0] == .count(8) && near(oneSample[4], 0.88191710368819687)
              && oneSample[5] == .count(7),
              "One-sample t matches t.test(x, mu = 7)")
        guard case .probability(let oneSampleP) = oneSample[6] else { fatalError("no p") }
        check(abs(oneSampleP - 0.40708382206558869) < 1e-10, "As does its p-value")
        check(near(oneSample[7], 6.159384061322843 - 7) && near(oneSample[8], 8.840615938677157 - 7),
              "And its interval, expressed around the tested value")

        let pairedTest = try AnalysisKernel.run(
            AnalysisStep(operation: .pairedT(first: ColumnReference(index: 0, name: "a"),
                                             second: ColumnReference(index: 1, name: "b"))),
            on: snapshot(columns: ["a", "b"], rows: [["5", "9"], ["7", "7"], ["8", "8"], ["6", "10"]])
        ).tables[0].rows[0]
        check(pairedTest[0] == .count(4) && near(pairedTest[4], -1.7320508075688774)
              && pairedTest[5] == .count(3),
              "Paired t matches t.test(a, b, paired = TRUE)")
        check(near(pairedTest[7], -5.6747724620741566) && near(pairedTest[8], 1.6747724620741571),
              "As does its interval")

        // Unequal n and spread, so Welch and pooled genuinely differ.
        let uneven = snapshot(columns: ["x", "g"], rows: [
            ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"], ["7", "a"],
            ["9", "b"], ["2", "b"], ["18", "b"], ["10", "b"], ["14", "b"], ["3", "b"],
        ])
        let welch = try AnalysisKernel.run(
            AnalysisStep(operation: .independentT(outcome: outcome, group: grouping, variance: .welch)),
            on: uneven)
        let welchRow = welch.tables[1].rows[0]
        check(near(welchRow[2], -1.0609165962055893) && near(welchRow[3], 5.4047472978668401),
              "Welch matches t.test(var.equal = FALSE), fractional df included")
        check(near(welchRow[5], -9.2097198094024115) && near(welchRow[6], 3.7430531427357443),
              "As does its interval")
        let pooled = try AnalysisKernel.run(
            AnalysisStep(operation: .independentT(outcome: outcome, group: grouping, variance: .pooled)),
            on: uneven).tables[1].rows[0]
        check(near(pooled[2], -0.96596196678643031) && near(pooled[3], 9),
              "Pooled matches t.test(var.equal = TRUE) and differs from Welch")
        check(welch.tables[0].rows[0][1] == .count(5) && welch.tables[0].rows[1][1] == .count(6),
              "Group descriptives report each group's n")
        let levene = welch.tables[2].rows[0]
        check(near(levene[0], 5.6771569792904995) && levene[1] == .count(1) && levene[2] == .count(9),
              "Levene's test matches an ANOVA on absolute deviations from the group means")
        check(welch.tables[2].caption?.contains("does not decide the test for you") == true,
              "And is offered as evidence, not as a rule")

        var wrongLevels = false
        do {
            _ = try AnalysisKernel.run(
                AnalysisStep(operation: .independentT(outcome: ColumnReference(index: 0, name: "y"),
                                                      group: ColumnReference(index: 1, name: "f"),
                                                      variance: .welch)),
                on: snapshot(columns: ["y", "f"], rows: [["1", "a"], ["2", "b"], ["3", "c"], ["4", "c"]]))
        } catch let error as CSVAnalysisError {
            wrongLevels = error.localizedDescription.contains("One-Way ANOVA")
        }
        check(wrongLevels, "Three groups refuses a t test and names the test that fits, rather than switching")

        let anova = try AnalysisKernel.run(
            AnalysisStep(operation: .oneWayANOVA(outcome: ColumnReference(index: 0, name: "y"),
                                                 factor: ColumnReference(index: 1, name: "f"))),
            on: snapshot(columns: ["y", "f"], rows: [
                ["5", "a"], ["7", "a"], ["8", "a"], ["6", "a"],
                ["9", "b"], ["7", "b"], ["8", "b"], ["10", "b"],
                ["12", "c"], ["11", "c"], ["13", "c"], ["12", "c"],
            ]))
        let between = anova.tables[1].rows[0]
        check(near(between[1], 61.999999999999936) && between[2] == .count(2)
              && near(between[4], 23.250000000000028),
              "One-way ANOVA matches summary(aov(y ~ f))")
        guard case .probability(let anovaP) = between[5] else { fatalError("no p") }
        check(abs(anovaP - 0.00027846644366968628) < 1e-10, "As does its p-value")
        check(near(anova.tables[1].rows[1][1], 11.999999999999973) && anova.tables[1].rows[1][2] == .count(9),
              "And its within-groups sum of squares and df")
        check(near(between[6], 61.999999999999936 / 73.99999999999991), "η² is the between share of total")

        check(Distributions.inverseT(0.975, df: 10) - 2.2281388519862735 < 1e-10
              && abs(Distributions.inverseT(0.975, df: 1) - 12.706204736174692) < 1e-9
              && abs(Distributions.inverseT(0.975, df: 3.7) - 2.8675207071911917) < 1e-9,
              "The inverse t matches qt(), fractional df included")

        check(NotebookReport.text(.probability(0.0004)) == "< .001"
              && NotebookReport.text(.probability(0.0426)) == ".043"
              && NotebookReport.text(.probability(1)) == "1.000",
              "p-values print to APA convention")

        // A notebook written before significance testing must still open.
        let legacy = Data(#"{"version":1,"missingCodes":["NA"],"steps":[{"id":"\#(UUID())","operation":{"frequency":{"column":{"index":0,"name":"g"}}}}]}"#.utf8)
        let opened = try JSONDecoder().decode(AnalysisNotebookFile.self, from: legacy)
        check(opened.steps.first?.adjustment == .holm && opened.steps.first?.missing == .pairwise
              && opened.steps.first?.scope == .allRows,
              "A step saved before these fields existed adopts the current defaults")

        // MARK: Regression
        //
        // Expected values are R's, via summary(lm(y ~ x1 + x2)), confint(),
        // anova(), and diag(solve(cor(cbind(x1, x2)))) for the inflations.

        let regressionData = snapshot(columns: ["y", "x1", "x2"], rows: [
            ["52", "3", "11"], ["61", "5", "14"], ["48", "2", "9"], ["70", "8", "17"],
            ["66", "7", "16"], ["55", "4", "12"], ["73", "9", "19"], ["59", "5", "13"],
            ["64", "6", "15"], ["68", "7", "16"], ["57", "4", "12"], ["72", "8", "18"],
        ])
        let regressionStep = AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1")),
                         RegressionPredictor(column: ColumnReference(index: 2, name: "x2"))]))
        let fitted = try AnalysisKernel.run(regressionStep, on: regressionData)

        let modelSummary = fitted.tables[0].rows[0]
        check(modelSummary[0] == .count(12) && near(modelSummary[2], 0.9892464792354676)
              && near(modelSummary[3], 0.9868568079544604)
              && near(modelSummary[4], 0.92810394200563007),
              "Model summary matches summary(lm(y ~ x1 + x2))")

        let variance = fitted.tables[1].rows
        check(near(variance[0][1], 713.16427432216722) && variance[0][2] == .count(2)
              && near(variance[1][1], 7.75239234449751) && variance[1][2] == .count(9),
              "The regression ANOVA matches anova(lm(...))")
        check(near(variance[0][4], 413.96759759296918), "As does the model F")
        guard case .probability(let modelP) = variance[0][5] else { fatalError("no model p") }
        check(abs(modelP - 1.3866857454165045e-09) < 1e-20, "And its p-value, far into the tail")

        let coefficients = fitted.tables[2].rows
        check(coefficients[0][0] == .text("(Intercept)") && coefficients[1][0] == .text("x1"),
              "Coefficients are named, with the intercept first")
        check(near(coefficients[0][1], 30.6877990430621566) && near(coefficients[1][1], 1.4497607655502180)
              && near(coefficients[2][1], 1.6172248803827878),
              "Estimates match lm() to the digits R prints")
        check(near(coefficients[0][2], 5.3422661877737729) && near(coefficients[1][2], 1.1156473693116087)
              && near(coefficients[2][2], 0.8069600183745006),
              "As do the standard errors, taken from a QR rather than from XᵀX")
        check(near(coefficients[1][4], 1.2994793923502623), "As does t")
        guard case .probability(let slopeP) = coefficients[1][5] else { fatalError("no p") }
        check(abs(slopeP - 0.22607732413998454) < 1e-12, "As does its p-value")
        check(near(coefficients[1][6], -1.07400892209501131) && near(coefficients[1][7], 3.9735304531954476),
              "And the interval confint() gives")
        check(near(coefficients[1][3], 0.39185169123257912) && near(coefficients[2][3], 0.60432522901829733),
              "Standardized β is the coefficient in standard deviations")
        check(coefficients[0][3] == .missing, "The intercept has no standardized coefficient")
        check(near(coefficients[1][8], 76.102073365233792) && near(coefficients[2][8], 76.102073365233792),
              "VIF matches diag(solve(cor(predictors)))")
        check(fitted.notes.contains { $0.contains("variance inflation") },
              "And a high one is called out rather than left to be noticed")

        // Rank deficiency has to surface as rank deficiency.
        var collinear = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1")),
                             RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))])),
                on: regressionData)
        } catch let error as CSVAnalysisError {
            collinear = error.localizedDescription.contains("collinear")
        }
        check(collinear, "A duplicated predictor is refused rather than fitted")

        var selfPredicted = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 0, name: "y"))])),
                on: regressionData)
        } catch { selfPredicted = true }
        check(selfPredicted, "An outcome cannot also be its own predictor")

        // One predictor: the slope's t test is the correlation's, and no VIF exists.
        let simple = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))])),
            on: regressionData)
        check(simple.tables[2].columns.count == 8,
              "A single predictor reports no variance inflation, having nothing to be inflated by")
        let simpleRow = simple.tables[2].rows[1]
        let correlated = try AnalysisKernel.run(AnalysisStep(adjustment: .none, operation: .correlation(
            columns: [ColumnReference(index: 0, name: "y"), ColumnReference(index: 1, name: "x1")],
            method: .pearson)), on: regressionData).tables[1].rows[0]
        guard case .probability(let regressionP) = simpleRow[5],
              case .probability(let correlationTestP) = correlated[6] else { fatalError("no p") }
        check(abs(regressionP - correlationTestP) < 1e-9,
              "A simple regression's slope test and the correlation's test are the same test")

        // Incomplete rows are dropped for the whole model, not per column.
        let gappy = snapshot(columns: ["y", "x1", "x2"], rows: [
            ["52", "3", "11"], ["61", "5", "14"], ["48", "", "9"], ["70", "8", "17"],
            ["66", "7", "16"], ["55", "4", "12"], ["73", "9", "19"], ["59", "5", "13"],
        ])
        let dropped = try AnalysisKernel.run(regressionStep, on: gappy)
        check(dropped.tables[0].rows[0][0] == .count(7)
              && dropped.notes.contains { $0.contains("incomplete across the outcome and predictors") },
              "A row missing any term leaves the model, and the count is reported")

        // MARK: Categorical predictors
        //
        // Expected values are R's, via summary(lm(y ~ x1 + f)) with f a factor,
        // confint(), anova(), and relevel(f, ref = "c").

        let withFactor = snapshot(columns: ["y", "x1", "f"], rows: [
            ["52", "3", "a"], ["61", "5", "b"], ["48", "2", "a"], ["70", "8", "c"],
            ["66", "7", "c"], ["55", "4", "b"], ["73", "9", "c"], ["59", "5", "a"],
            ["64", "6", "b"], ["68", "7", "c"], ["57", "4", "b"], ["72", "8", "c"],
        ])
        let scale = RegressionPredictor(column: ColumnReference(index: 1, name: "x1"))
        let factorColumn = ColumnReference(index: 2, name: "f")
        let dummied = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true)])),
            on: withFactor)

        let dummyTerms = dummied.tables[2].rows
        check(dummyTerms.count == 4,
              "A three-level factor contributes two indicators, not three")
        check(dummyTerms[2][0] == .text("f = b") && dummyTerms[3][0] == .text("f = c"),
              "Indicators are named for the level they carry")
        check(near(dummyTerms[0][1], 40.91190864600329746) && near(dummyTerms[1][1], 3.62642740619901938)
              && near(dummyTerms[2][1], 1.11256117455136616) && near(dummyTerms[3][1], 0.60195758564435808),
              "Estimates match lm(y ~ x1 + f) with a as the baseline")
        check(near(dummyTerms[2][2], 0.94649189990708116) && near(dummyTerms[3][2], 1.69003398054689846),
              "As do the indicator standard errors")
        check(near(dummyTerms[2][6], -1.0700530605716101) && near(dummyTerms[2][7], 3.2951754096743424),
              "And the intervals confint() gives")
        check(near(dummied.tables[0].rows[0][2], 0.987251141462962)
              && near(dummied.tables[0].rows[0][4], 1.0718479719814684),
              "As do R² and the residual standard error")
        check(near(dummied.tables[1].rows[0][1], 711.72580206633836) && dummied.tables[1].rows[0][2] == .count(3)
              && near(dummied.tables[1].rows[1][1], 9.190864600326293),
              "And the regression ANOVA, with the factor costing two degrees of freedom")
        check(dummied.notes.contains { $0.contains("dummy coded against “a”") },
              "The result names the baseline every coefficient is measured from")

        let relevelled = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true,
                                                    referenceLevel: "c")])), on: withFactor)
        check(near(relevelled.tables[2].rows[0][1], 41.513866231647661)
              && near(relevelled.tables[2].rows[2][1], -0.60195758564435697)
              && near(relevelled.tables[2].rows[3][1], 0.51060358890700897),
              "Choosing a different baseline matches relevel(f, ref = \"c\")")
        check(near(relevelled.tables[0].rows[0][2], 0.987251141462962),
              "The fit itself does not depend on which level is held out")
        check(relevelled.notes.contains { $0.contains("per indicator") },
              "Multi-level inflation factors are flagged as per indicator, not per variable")

        // The same column read as a number rather than as a factor is a different model.
        let asNumbers = snapshot(columns: ["y", "x1", "code"], rows: [
            ["52", "3", "1"], ["61", "5", "2"], ["48", "2", "1"], ["70", "8", "3"],
            ["66", "7", "3"], ["55", "4", "2"], ["73", "9", "3"], ["59", "5", "1"],
            ["64", "6", "2"], ["68", "7", "3"], ["57", "4", "2"], ["72", "8", "3"],
        ])
        let codeColumn = ColumnReference(index: 2, name: "code")
        let asScale = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: codeColumn)])), on: asNumbers)
        let asFactor = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
            outcome: ColumnReference(index: 0, name: "y"),
            predictors: [scale, RegressionPredictor(column: codeColumn, isCategorical: true)])),
            on: asNumbers)
        check(asScale.tables[2].rows.count == 3 && asFactor.tables[2].rows.count == 4,
              "A numeric-looking code entered as a factor is a different model than entered as a scale")

        var oneLevelFactor = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [RegressionPredictor(column: ColumnReference(index: 1, name: "g"),
                                                 isCategorical: true)])),
                on: snapshot(columns: ["y", "g"], rows: [["1", "a"], ["2", "a"], ["3", "a"], ["4", "a"]]))
        } catch { oneLevelFactor = true }
        check(oneLevelFactor, "A factor with one level is refused rather than coded into nothing")

        var absentBaseline = false
        do {
            _ = try AnalysisKernel.run(AnalysisStep(operation: .linearRegression(
                outcome: ColumnReference(index: 0, name: "y"),
                predictors: [scale, RegressionPredictor(column: factorColumn, isCategorical: true,
                                                        referenceLevel: "z")])), on: withFactor)
        } catch let error as CSVAnalysisError {
            absentBaseline = error.localizedDescription.contains("a, b, c")
        }
        check(absentBaseline, "A baseline that is not a level fails and lists the ones that are")

        // MARK: The R script
        //
        // The emitted script is checked by running it. Structure assertions can
        // pass on code R would reject, so the real test is Rscript's exit status.

        let y = ColumnReference(index: 0, name: "y")
        let x = ColumnReference(index: 1, name: "x 1 (raw)")
        let fColumn = ColumnReference(index: 2, name: "f")
        let gColumn = ColumnReference(index: 3, name: "g")
        let scriptSteps: [AnalysisStep] = [
            AnalysisStep(operation: .describe(columns: [y, x])),
            AnalysisStep(operation: .frequency(column: fColumn)),
            AnalysisStep(operation: .crossTabulation(rows: fColumn, columns: gColumn)),
            AnalysisStep(operation: .chiSquareIndependence(rows: fColumn, columns: gColumn)),
            AnalysisStep(adjustment: .holm, operation: .correlation(columns: [y, x], method: .pearson)),
            AnalysisStep(missing: .listwise,
                         operation: .correlation(columns: [y, x], method: .spearman)),
            AnalysisStep(operation: .oneSampleT(column: y, testValue: 7)),
            AnalysisStep(operation: .independentT(outcome: y, group: gColumn, variance: .welch)),
            AnalysisStep(operation: .pairedT(first: y, second: x)),
            AnalysisStep(operation: .oneWayANOVA(outcome: y, factor: fColumn)),
            AnalysisStep(operation: .linearRegression(outcome: y, predictors: [
                RegressionPredictor(column: x),
                RegressionPredictor(column: fColumn, isCategorical: true, referenceLevel: "b"),
            ])),
        ]
        let script = NotebookScript.r(
            steps: scriptSteps, missingCodes: ["NA"],
            sources: ["": NotebookScript.Source(frame: "data1", path: "data.csv")])

        check(script.hasPrefix("# %% Setup"), "The script opens with a setup cell")
        // Counted the way the editor parses them: a delimiter is a line that
        // starts with the marker, not any mention of it.
        let cells = script.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(NotebookScript.cellMarker) }
        check(cells.count == scriptSteps.count + 1, "Every step becomes one cell, plus setup")
        check(script.contains("x_1_raw = as.numeric(data1[[2]])"),
              "A header that is not a valid identifier is read by position and renamed")
        check(script.contains("as.character(data1[[3]])"),
              "A column used as a factor is read as character, not coerced to a number")
        check(script.contains("relevel(factor(d$f), ref = \"b\")"),
              "The chosen baseline carries into the script")
        check(script.contains("lm(y ~ x_1_raw + f, data = d)"),
              "The model formula uses the renamed identifiers")
        check(script.contains("var.equal = FALSE"), "Welch carries into t.test")
        check(script.contains("p.adjust(raw, \"holm\")"), "So does the multiplicity adjustment")
        check(script.contains("use = \"complete.obs\"") && script.contains("use = \"pairwise.complete.obs\""),
              "And the missing policy, per step")
        check(script.contains("car::vif(model)"),
              "The regression cell points at the diagnostics the notebook does not do")
        check(script.contains("na.strings = missing"), "Declared missing codes reach read.csv")

        // A notebook with no steps still writes a usable script.
        let starter = NotebookScript.r(
            steps: [], missingCodes: [],
            sources: ["": NotebookScript.Source(frame: "data1", path: "data.csv")])
        check(starter.contains("read.csv(\"data.csv\"") && starter.contains("str(data1"),
              "An empty notebook still writes a script that loads the table")
        let starterCells = starter.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix(NotebookScript.cellMarker) }
        check(starterCells.count == 2, "With a setup cell and somewhere to start writing")

        let scriptRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: scriptRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scriptRoot) }
        try Data("""
        y,x 1 (raw),f,g
        52,3,a,p
        61,5,b,q
        48,2,a,p
        70,8,c,q
        66,7,c,q
        55,4,b,p
        73,9,c,q
        59,5,a,p
        64,6,b,q
        68,7,c,q
        57,4,b,p
        72,8,c,q
        """.utf8).write(to: scriptRoot.appendingPathComponent("data.csv"))
        try Data(script.utf8).write(to: scriptRoot.appendingPathComponent("analysis.R"))

        if let rscript = locate("Rscript") {
            let run = Process()
            run.executableURL = rscript
            run.arguments = ["analysis.R"]
            run.currentDirectoryURL = scriptRoot
            let output = Pipe()
            run.standardOutput = output
            run.standardError = output
            try run.run()
            let produced = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            run.waitUntilExit()
            check(run.terminationStatus == 0,
                  "The generated script runs under Rscript without error")
            if run.terminationStatus != 0 { print(produced) }
            check(produced.contains("Pearson's Chi-squared test") && produced.contains("Welch")
                  && produced.contains("Coefficients"),
                  "And produces the analyses it was generated from")

            try Data(starter.utf8).write(to: scriptRoot.appendingPathComponent("starter.R"))
            let starterRun = Process()
            starterRun.executableURL = rscript
            starterRun.arguments = ["starter.R"]
            starterRun.currentDirectoryURL = scriptRoot
            starterRun.standardOutput = Pipe()
            starterRun.standardError = Pipe()
            try starterRun.run()
            starterRun.waitUntilExit()
            check(starterRun.terminationStatus == 0, "The empty-notebook script runs too")
        } else {
            print("SKIP: Rscript is not installed; the emitted script was not executed")
        }

        print(failures == 0 ? "All analysis checks passed" : "\(failures) analysis checks FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: Harness

    /// Nil when the tool is absent, so the script check degrades to a skip on a
    /// machine without R rather than failing.
    nonisolated static func locate(_ tool: String) -> URL? {
        let which = Process()
        which.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        which.arguments = [tool]
        let pipe = Pipe()
        which.standardOutput = pipe
        which.standardError = Pipe()
        guard (try? which.run()) != nil else { return nil }
        let found = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        which.waitUntilExit()
        guard which.terminationStatus == 0, !found.isEmpty else { return nil }
        return URL(fileURLWithPath: found)
    }

    nonisolated static func snapshot(columns: [String], rows: [[String]]) -> CSVAnalysisSnapshot {
        CSVAnalysisSnapshot(table: CSVTable(columns: columns, rows: rows),
                            sourceRows: Array(rows.indices), columnTypes: [:])
    }

    nonisolated static func near(_ cell: AnalysisCell, _ expected: Double) -> Bool {
        guard case .number(let value) = cell else { return false }
        return abs(value - expected) < 1e-9
    }

    nonisolated(unsafe) static var failures = 0

    static func check(_ value: Bool, _ description: String) {
        if !value { failures += 1 }
        print("\(value ? "PASS" : "FAIL"): \(description)")
    }
}
