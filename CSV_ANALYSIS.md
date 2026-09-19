# Adding statistics actions to the CSV editor

The initial bridge is `EditorSession.csvAnalysisSnapshot(scope:)`. Call it from a
button action while a CSV is open. It commits an active cell edit before reading
storage, so the input contains the latest edits rather than only the saved file.

```swift
let input = try session.csvAnalysisSnapshot(scope: .visibleRows)
let column = try await Task.detached(priority: .userInitiated) {
    try input.numericColumn(at: 0)
}.value
// Implement your calculation using column.values and an explicit missing-data policy.
```

The snapshot is a Sendable value; calculations belong in separate functions or
services and can run off the main actor. Taking a snapshot is an explicit action,
not work performed while drawing, scrolling, or editing each cell.

- `.allRows`: all records in file order, regardless of sorting/filtering.
- `.visibleRows`: all records passing the filters, in displayed sort order. This
  means the filtered dataset, not only the cells currently inside the viewport.
- `table`: headers and raw strings, including unsaved edits.
- `sourceRows`: zero-based original record indices, aligned with snapshot rows.
- `columnTypes`: the column-header variable-type hints, keyed by column index.
- `csvText`: serialized captured data with headers, suitable for saving as the
  input to a manually run R script or other analysis tool.

Columns are addressed by index because headers can be empty or duplicated.
`numericColumn(at:)` preserves row alignment with `[Double?]`. Blanks, whitespace,
and absent cells in short records are missing; nonnumeric and non-finite values
are invalid. Both categories return their source-row indices. `NA` is not silently
classified as missing. Paired calculations must handle missingness jointly across
columns rather than compacting each column independently.

Type choices currently describe intent only. They do not coerce cells, drop `Skip`
columns, or validate `Integer`/date/factor semantics. They live with the open grid
and are not encoded into the CSV or persisted across reopening. Later schema
persistence can use a project sidecar without changing the raw table format.

The preview header's **Data** menu provides working all-row and filtered-row CSV
copy actions. Add analysis buttons beside those actions and call the same snapshot
API. Keep result presentation separate from grid storage, and associate long-running
results with their captured input rather than overwriting the table currently open.

R installation, execution, test algorithms, and result export are left for the
next layer. The existing project output-directory contract in `PROJECTS.md` can
supply destinations when you add those exporters.
