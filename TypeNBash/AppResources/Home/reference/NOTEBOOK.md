# The analysis notebook

A project can hold a notebook: an ordered list of statistics steps run against
the CSV tables in that project. It needs no Python or R installation — the
calculations are native — and it is meant to be the pure-CSV path through the
app, not a replacement for a scripted one.
## A step is a value, not code

`AnalysisStep` *describes* a calculation instead of performing one:

```swift
AnalysisStep(
    dataset: "survey.csv",
    scope: .allRows,
    missing: .pairwise,
    operation: .correlation(
        columns: [ColumnReference(index: 2, name: "age"),
                  ColumnReference(index: 5, name: "score")],
        method: .pearson
    )
)
```

That one decision is what the layer rests on. The same value serializes into the
project sidecar, replays against a later version of a file, and — when a
Python/R extension arrives — can be emitted as a script instead of being handed
to `AnalysisKernel`. The pure-CSV path and a scripted path become two backends
over one description rather than two separate features.

Views build and edit these values. `AnalysisKernel` is the only thing that runs
them, it is `nonisolated` and pure, and it runs off the main actor.

## Columns

Columns are addressed by index, because CSV headers can be blank or repeated.
The header text is carried alongside in `ColumnReference` so a replay can tell
"column 3" from "age": if the header at that position has changed, the result
says so in its notes rather than quietly computing a different variable. If the
position is gone entirely, the step fails instead of running.

Variable-type hints set in the grid's column menu still describe intent only.
They do not coerce cells, drop `Skip` columns, or select which columns a step
may read.

## Missing data

CSV carries no missing marker, so the notebook declares one. `missingCodes` on
the document lists the cell text that counts as missing. Blank cells always
count and need not be listed. Anything else that will not parse as a finite
number is *unusable*, counted apart from missing, and reported separately.

The default vocabulary is `NA` and blanks, and nothing else.

`N/A` is deliberately excluded. In survey and institutional research it usually
marks a question meaningfully skipped — a qualitative fact about the respondent,
often one you want to tabulate — rather than a value that went absent. Treating
it as missing by default would quietly inflate the missing count and shrink the
n in every statistic on the page. A project that genuinely uses it as a missing
marker can add it; the point is that the tool does not guess.

Changing the vocabulary re-runs every step that has already produced a result or
an error, because each one was computed under the old codes and would otherwise
sit on screen labelled as current. A step that has never run is left alone.

`MissingPolicy` is recorded on each step and printed with its result:

- `.pairwise` — each statistic uses the rows complete for the columns it needs,
  so a correlation matrix's N varies by pair.
- `.listwise` — one row set for the whole step, complete across every column it
  reads. The number of dropped rows is reported.
- `.fail` — any missing or unusable value stops the step.

A cross-tabulation is inherently paired: a row missing either variable has no
cell to land in under any policy, so those rows are excluded and counted, and
`.fail` is what turns that exclusion into an error instead.

## What the kernel computes

| Operation | Output |
| --- | --- |
| `describe` | N, missing, unusable, mean, sample SD, min, Q1, median, Q3, max |
| `frequency` | level, count, percent and cumulative percent of non-missing rows |
| `crossTabulation` | counts by row × column level, with row, column and grand totals |
| `chiSquareIndependence` | Pearson's χ², df, N, p, Cramér's V, and the expected counts |
| `oneSampleT` | N, mean, SD, difference from the tested value, t, df, p, 95% CI |
| `independentT` | group descriptives, difference, SE, t, df, p, 95% CI, and Levene's test |
| `pairedT` | pairs, mean difference, SD, SE, t, df, p, 95% CI |
| `oneWayANOVA` | group descriptives and the between/within/total table with F, p and η² |
| `linearRegression` | model summary, regression ANOVA, and coefficients with B, SE, β, t, p, CI and VIF |
| `correlation` | Pearson or Spearman matrix, plus a test per pair: N, r, df, t, p, adjusted p and a 95% interval |

Quartiles interpolate linearly (R's default `quantile` type 7, NumPy's default),
the deviation is the sample SD, and Spearman averages tied ranks — so numbers
match what the same data gives in R. `Tests/AnalysisIntegrationChecks.swift`
pins them to those values.

## Significance

macOS has no statistics library: Accelerate is linear algebra and signal
processing, and there is no t, F or chi-square anywhere in the system. All three
reduce to two functions — the regularized incomplete beta and the regularized
incomplete gamma — which `Distributions` evaluates by continued fraction on top
of libm's `lgamma`. Only the normal distribution comes free, from `erfc`.

Upper tails are computed directly rather than as `1 - CDF`, so a p-value of
2.4e-25 keeps its digits instead of being rounded off against 1. Every function
is pinned against R to twelve significant digits in
`Tests/AnalysisIntegrationChecks.swift`, with the generating R expression beside
each constant.

Correlation reports a two-sided test of H₀: ρ = 0 per pair, with a Fisher z
interval. Spearman has no exact small-sample test here — it borrows the t
approximation and the Bonett–Wright interval, both asymptotic, and the result
says so rather than letting the reader assume otherwise.

A correlation matrix is a family of tests: ten variables is forty-five of them,
and reporting those raw is how a chance result becomes a finding. `adjustment`
on the step offers Holm (family-wise error, the default) and Benjamini–Hochberg
(false discovery rate), and the table prints raw and adjusted p side by side
with the method named. A single pair is one test and is unaffected.

Cross-tabulation carries Pearson's chi-square test of independence and Cramér's
V. The expected-count rule is reported, not enforced: cells expecting fewer than
five are counted in the notes, and the analyst decides whether the approximation
holds.

p-values print to APA convention — three decimals, no leading zero, `< .001`
below that — because the exact value of a very small p is not what is reported.

Confidence intervals need a t quantile, which `Distributions.inverseT` finds by
bisection on the CDF. A mean difference's interval does not need Newton's speed,
and bisection cannot be thrown off by a flat tail the way a derivative step can.

## Regression

Everything above is a direct formula. Regression is the one operation that needs
real linear algebra, and the one place hand-rolling it would be a mistake, so
`LeastSquares` sits on Accelerate's LAPACK.

Coefficients come from `dgelsd_`, which decides rank by singular value. That
matters because the failure mode is not an exception — two predictors measuring
the same thing, or a dummy set that sums to the intercept, otherwise produce a
fit that looks entirely plausible. A rank-deficient design is refused and
reported as collinearity instead.

Standard errors come from a *separate* QR of the same matrix, via
`(XᵀX)⁻¹ = R⁻¹R⁻ᵀ`. Forming `XᵀX` to invert it would square the condition
number, and a design with a VIF in the dozens is exactly where that begins to
show. Two decompositions of one matrix is a real cost and a deliberate one.

Using LAPACK requires `ACCELERATE_NEW_LAPACK=1`; the app target passes it
through `OTHER_SWIFT_FLAGS`. Without it `__LAPACK_int` does not exist and the
symbols merely look missing. One Swift-specific trap is worth knowing: every
LAPACK scalar needs its own variable, because passing `&rows` as both the row
count and the leading dimension is two overlapping accesses to one `var` and
traps at runtime.

### Categorical predictors

A predictor enters as a number or as a set of indicators because the step says
so, never because of how its contents parse. A department coded 1, 2, 3 is
numeric to a parser and categorical to an analyst, and reading those codes as a
scale is a silent, plausible-looking mistake. The grid's declared variable types
preselect the checkbox in the composer and nothing more — they still describe
intent and never coerce.

A factor with k levels contributes k−1 indicators, one per level except the
baseline. Coding all k would make the design exactly rank deficient against the
intercept, which is what a baseline exists to prevent, and `dgelsd_` would
refuse the fit. The baseline is chosen in the composer and defaults to the first
level in sort order; the result always names it, because every coefficient for
that variable is a difference from it. Changing the baseline changes what the
coefficients mean and not the fit — a check asserts R² is identical across two
choices of it, matching `relevel()`.

Inflation factors are per indicator, not per variable, so for a factor with more
than two levels they move with the baseline. That is reported in the notes
rather than papered over; a generalized VIF would be the term-level measure and
is not implemented.

The output is a model summary, the regression ANOVA, and a coefficient table
with B, SE, standardized β, t, p and a 95% interval. With more than one
predictor each gets a variance inflation factor, computed by regressing it on
the others through the same solver; anything at or above 10 is called out in the
notes rather than left to be noticed. A regression is complete-case by
construction — a row missing any term has no place in the design matrix under
any policy — and the number of rows dropped is reported.

A simple regression's slope test and the corresponding correlation test are the
same test, and a check asserts they agree.

## One step, one named test

Every operation is a test the user chose by name. Nothing inspects the data and
decides on their behalf which test was meant — a grouping column's level count
is not a proxy for whether the question was a t-test or an ANOVA, and a
cross-tabulation is a description, not a hypothesis.

So the menu is grouped the way a statistics package groups it — Descriptives,
Compare Means, Correlate, Categorical — and each entry composes exactly one
operation. A cross-tabulation returns counts; testing those counts is a separate
Chi-Square step against the same two columns. An independent-samples t test on a
three-level factor fails and names One-Way ANOVA rather than quietly running it.

Levene's test is reported alongside every independent-samples t test for the
same reason: it is evidence for choosing Welch over pooled, not a rule that
picks one. Welch is the default because it does not assume equal variances and
costs almost nothing when they hold. The pooled test is kept because it is what
a classical write-up reports, and because it is the one that equals a linear
model on a two-level factor — which will matter when regression lands.

A paired test is a one-sample test on the differences, not a two-sample test on
the columns, and shares its implementation accordingly.

## Capture, not live data

Opening the notebook replaces the editor pane, which unmounts the grid. The
toolbar action therefore captures the open table on the way in — both scopes,
including uncommitted cell edits — and steps with an empty `dataset` read that
capture. Steps naming a file read it through the active workspace filesystem,
except when the capture is that same file, where the capture wins so unsaved
edits are not silently ignored.

This is also the honest model for analysis: a result belongs to data taken at a
known moment. Every result carries an `AnalysisInputSummary` — dataset, scope,
row and column counts, a content fingerprint and a timestamp — which is shown
with it on screen and written into the export. Closing and reopening the
notebook takes a fresh capture; the pane warns when the table has been edited
since the current one.

## The sidecar

Steps are document content and live in `.typenbash-notebook.json` in the project
root, beside `.typenbash.json`:

```json
{
  "version": 1,
  "missingCodes": ["NA"],
  "steps": [ ... ]
}
```

Paths inside are project-relative, so the file travels with a copied folder
exactly as the project definition does. Loading rejects an unsupported version,
a path escaping the project, and a negative column position. A project with no
notebook loads as an empty notebook rather than an error.

Results are *not* stored there. A number saved next to data that has since moved
on is worse than no number at all, and it keeps the file small and diff-friendly
in Git. Steps are re-run on demand.

## Handing off to R

No statistics package covers every diagnostic, and past a point the honest
answer is a script and a console rather than reimplementing R badly. **New R
Notebook** writes the notebook's steps out as an `.R` file in the project root
and opens it in the editor, which already highlights R.

A notebook with no steps still writes a script: it loads the captured table and
stops there, with a cell to start writing in. Wanting to script against a CSV is
a reason to ask for this, and requiring steps you do not want first would be
backwards.

The script is delimited into cells with `# %%`, as Jupyter and Positron use.
In the editor, the run action sends the selection — or, with nothing selected,
the cell the caret sits in — to the project console, and a caret resting on a
delimiter means the cell it introduces. This is the RStudio gesture, and the
console is the result surface: output lands there and stays there.

**One way only.** Nothing parses R's output back into a result. That would mean
owning a fragile contract with another program's formatting, for no gain the
console does not already provide.

Columns are read by position and renamed to safe identifiers, because a header
can be blank, repeated, or full of punctuation, and no header should be able to
produce invalid R. The step's own settings carry across: the missing-code
vocabulary reaches `na.strings`, Welch or pooled reaches `var.equal`, the
multiplicity choice reaches `p.adjust`, and a categorical predictor's baseline
reaches `relevel`. The regression cell ends in commented pointers to the things
the notebook deliberately does not do — `car::vif` for generalized VIF,
`plot(model)` for residual diagnostics, `lmtest::dwtest`.

The script's paths are project-relative, which keeps it portable, so the console
has to be at the project root for its reads to resolve. It normally already is.
Opening a script checks the console's last reported directory and only sends a
`cd` when it is somewhere else — moving it unconditionally would paste a `cd`
into whatever holds the foreground, and an R session would answer with a syntax
error. A live R session reports nothing, so the recorded directory stays the
shell's, which is the one that matters.

Two differences are worth knowing, and the script's header says the first: R
coerces a non-numeric cell to `NA`, whereas the notebook counts *missing* and
*unusable* apart, so an N can differ between the two. And the console runs a
shell, so `R` has to be started there before a cell will do anything.

The emitted script is verified by running it: the checks execute a script
covering every operation under `Rscript` and assert it exits cleanly, because
structural assertions can pass on code R would reject. On a machine without R
that check skips rather than fails.

A Python emitter would be the same shape — a second `body` switch over the same
steps — which is what a step being a value rather than code buys.

## Export

`Export` writes the results as they stand to the project's output directory
through `WindowSession.prepareProjectOutputDirectory()`, as Markdown with each
step's input summary, its notes, and its tables in full — long tables are cut
off in the pane but complete in the file. `NotebookReport.text(_:)` formats
cells for both, so a number never reads one way on screen and another in the
report.

## Not yet

- A Python emitter alongside the R one.
- Residual diagnostics and generalized VIF, which the R hand-off now covers.
- Factorial and repeated-measures designs.
- Post-hoc comparisons after a significant ANOVA, and Welch's ANOVA.
- Nonparametric distribution comparison: Mann–Whitney, Kruskal–Wallis, KS.
- Reordering steps; they are independent calculations, so order is presentational.
- Datasets are the project root's CSV files plus the captured table. Nested
  folders are not scanned.
- Emitting R or Python from a step, which is what the value-typed step is for.
