# The CSV analysis bridge

`EditorSession.csvAnalysisSnapshot(scope:)` is how data leaves the grid. It
commits an active cell edit before reading storage, so the input contains the
latest edits rather than only the saved file.

```swift
let input = try session.csvAnalysisSnapshot(scope: .visibleRows)
let column = try await Task.detached(priority: .userInitiated) {
    try input.numericColumn(at: 0, missingCodes: ["NA"])
}.value
```

The snapshot is a `Sendable` value; calculations belong in separate functions or
services and run off the main actor. Taking a snapshot is an explicit action,
not work performed while drawing, scrolling, or editing each cell.

- `.allRows`: all records in file order, regardless of sorting/filtering.
- `.visibleRows`: all records passing the filters, in displayed sort order. This
  means the filtered dataset, not only the cells currently inside the viewport.
- `table`: headers and raw strings, including unsaved edits.
- `sourceRows`: zero-based original record indices, aligned with snapshot rows.
- `columnTypes`: the column-header variable-type hints, keyed by column index.
- `csvText`: serialized captured data with headers, suitable for saving as the
  input to a manually run R script or other analysis tool.
- `fingerprint`: a content hash of those exact cells, so a result computed from
  one capture can be told apart from the table as it stands now.
- `inputSummary(dataset:scope:)`: that fingerprint with the shape and timestamp,
  for attaching to a result.

Columns are addressed by index because headers can be empty or duplicated.
`numericColumn(at:missingCodes:)` and `textColumn(at:missingCodes:)` preserve row
alignment with `[Double?]` and `[String?]`. Blanks, whitespace, absent cells in
short records, and any declared missing code are missing; other nonnumeric and
non-finite values are invalid. Both categories return their source-row indices.
`NA` is not silently classified as missing — pass it in `missingCodes` to make it
so. Paired calculations must handle missingness jointly across columns rather
than compacting each column independently.

Type choices currently describe intent only. They do not coerce cells, drop
`Skip` columns, or validate `Integer`/date/factor semantics. They live with the
open grid and are not encoded into the CSV or persisted across reopening.

The preview header's **Data** menu provides all-row and filtered-row CSV copy
actions built on this API.

## The layer above

`NOTEBOOK.md` describes what consumes these snapshots: value-typed analysis
steps, a native statistics kernel, a project sidecar, and the notebook pane.
R and Python execution remain a separate future layer, and the step values are
shaped so it can reuse them rather than replace them.
