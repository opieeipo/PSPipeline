# PSPipeline build record

PSPipeline reproduces a focused subset of Power Query / M (file-based ETL) in a form
that runs in locked-down environments: no installs, no admin, no network, Constrained
Language Mode safe, compiled to a single portable script. This began as a roadmap; with
the parity track delivered it is now mostly a record of what was built -- plus the few
items still open, and what the project will deliberately never do.

## Status

Foundation (done):
1. Plain-text format scope (delimited, fixed-width, JSON; Excel and XML deliberately excluded).
2. Backend interface + in-browser PowerShell generation (the designer emits a zero-dependency `.ps1`).
3. POSIX `sh` + `awk` backend for *nix.
4. Designer data preview: schema-aware column propagation, live per-node row preview, column-aware field builders, undo/redo, read-only input path.

Backends (done): all four targets ship -- PowerShell, POSIX `sh`+`awk`, the in-browser
preview executor (`tools/samplerun.js`), and the Power Query **M** export (see the M section
below). Every node is implemented across all four, except where a target deliberately declines
(awk declines pivot; the M and shell targets decline a few input types). Where a node is
runtime-verifiable it is diffed byte-for-byte against the PowerShell oracle; M is verified
structurally.

Transform-parity track (done): all nine numbered M-gap items below are implemented.

Remaining (small, data-dependent tails of otherwise-finished items):
- **Combine-all-files-in-a-folder** -- a folder input source (item 1).
- **Split-into-N-columns** -- column count is data-dependent (item 3).
- **Rank** aggregation -- cross-engine tie-ordering parity is the fiddly bit (item 7).

## Design rule

Every transform node must be implementable across the code-generation backends
(PowerShell, POSIX `sh`+`awk`, and the M export) and the in-browser preview
executor (`tools/samplerun.js`) -- or be explicitly marked target-specific. Adding a node
is therefore N implementations, not one. Some transforms (pivot, window functions) are
cheap in M and PowerShell but hard in POSIX awk; where that is true, the awk backend may
decline that node with a clear message rather than emit something subtly wrong. Track
feasibility per node, per backend.

Two facts shaped the whole build and still hold:

- **The M backend is a verification cliff.** M output cannot be runtime-verified in this
  environment (no Excel / Power Query engine). PowerShell, awk, and preview get diffed against
  the oracle; M can only be syntax-shaped until it is run in Excel/Power BI.
- **Data-dependent columns** (split-into-N, pivot) are the recurring hard case: when output
  columns depend on the data, static schema propagation and the column-aware dropdowns degrade,
  and the backends must discover columns at run time (or, like awk with pivot, decline).

## M / Power Query export (a gateway, not a competitor)

**Status: v1 shipped** -- the `mquery` backend (a Generate target in the designer, `tools/mquery.js`).
It covers every node except fixed-width input. Columns export as text and aggregations coerce
numbers internally; the user sets column types in Power Query as needed. As flagged below, this
backend cannot be runtime-verified outside Excel/Power BI, so it is verified structurally here
and validated by the user on paste.

The `mquery` backend compiles a pipeline to Power Query **M code** the user can
paste into Excel or Power BI.

The insight: our target users can already get data into a CSV. What they lack is the
confidence to navigate M / Power Query. PSPipeline's visual designer is the on-ramp --
build the flow here, see it work, then **Generate M** to take it into Excel/Power BI when
they are ready to go further (and to reach the DAX/modeling layer that is out of scope for
us). It is positioning PSPipeline as the bridge *to* the Microsoft BI stack, not a rival.

Most nodes map almost directly:

| PSPipeline node | Power Query M |
| --- | --- |
| `input.csv` | `Csv.Document` + `Table.PromoteHeaders` |
| `input.json` | `Json.Document` |
| `transform.select` / `drop` | `Table.SelectColumns` / `Table.RemoveColumns` |
| `transform.rename` | `Table.RenameColumns` |
| `transform.reorder` | `Table.ReorderColumns` |
| `transform.derive` | `Table.AddColumn` |
| `transform.filter` | `Table.SelectRows` |
| `transform.sort` | `Table.Sort` |
| `transform.distinct` | `Table.Distinct` |
| `transform.join` | `Table.NestedJoin` + `Table.ExpandTableColumn` |
| `transform.aggregate` | `Table.Group` |
| `transform.conditional` | `Table.AddColumn` + nested `if`/`then`/`else` |
| `transform.text` | `Text.Trim` / `Text.Lower` / `Text.Upper` / `Text.Proper` / `Text.BetweenDelimiters` ... |
| `transform.limit` | `Table.FirstN` / `Table.LastN` / `Table.Range` |
| `transform.index` | `Table.AddIndexColumn` |
| `transform.replace` | `Table.ReplaceValue` |
| `transform.fill` | `Table.FillDown` / `Table.FillUp` |
| `transform.union` | `Table.Combine` |
| `transform.date` | `Date.Year` / `Date.Month` / `Date.DayOfWeek` / `Date.ToText` / `Duration.Days` |
| `transform.cast` | `Table.TransformColumnTypes` |
| `transform.unpivot` | `Table.UnpivotOtherColumns` |
| `transform.pivot` | `Table.Pivot` |

Multi-input DAGs (joins, unions) map to multiple `let` queries. A bonus: emitting M is a
third-party validation of our pipeline semantics. The only node the M export does not
cover is fixed-width input (`input.fixedwidth`), which it declines.

## Transform parity with Power Query -- delivered

The gaps between PSPipeline and Power Query that the build closed, listed in the order they
were tackled (by value to the target persona: non-IT people doing extract/clean work in
locked-down shops). None of these broke the no-install / CLM-safe / portable constraints.
Three small data-dependent tails remain open; they are noted inline below and collected under
Status at the top.

1. **Union / append:** DONE -- the `transform.union` node stacks the rows of 2+ inputs
   (multiple edges into one port) and unions their columns in first-appearance order, with
   missing cells empty. This also built the multi-input infrastructure across the engine,
   the awk backend, the preview executor, and the designer's connection rules.
   **Combine-all-files-in-a-folder is still pending** (a folder input source).
2. **Conditional column (if/then/else).** DONE -- the `transform.conditional` node: a
   structured ordered-rules node (first matching `condition -> value` wins, with an
   `else`; results support `{Column}` templates), CLM-safe with no code eval.
3. **Text functions:** DONE except split -- the `transform.text` node (trim, lower / upper /
   title case, extract before / after / between, optional target column). Merge-columns is
   covered by the derive node's `{Column}` templates. **Split-into-N-columns still pending**
   (its column count is data-dependent).
4. **Date/time functions** + a light type layer. DONE -- the `transform.date` node
   (extract year/month/day/ISO-weekday, reformat to a fixed set of layouts, and whole-day
   difference between two date columns) and the `transform.cast` node (text/number/integer
   normalization). Input is restricted to ISO-ish dates (`yyyy-MM-dd`) and the date math is
   self-implemented as a Julian Day Number in every engine, so the result is byte-identical
   across PS/awk/preview (verified) and structurally correct in M -- which means the awk
   backend handles dates too, rather than declining as originally feared. Anticipated awk
   date-format parity problems were avoided by computing the layout ourselves instead of
   leaning on each platform's date formatter.
5. **Pivot / unpivot** (long <-> wide). DONE -- the `transform.unpivot` node (wide to long)
   runs in all engines and verifies byte-equal (PS/awk/preview, M via `Table.UnpivotOtherColumns`).
   The `transform.pivot` node (long to wide) runs in PowerShell + preview + M (`Table.Pivot`);
   its output columns are data-dependent, so the awk backend declines it with a clear message,
   as the per-backend feasibility rule allows.
6. **Richer aggregations** DONE -- Median, CountDistinct (case-insensitive), and StringJoin
   added to the aggregate node across all engines (PS/awk/preview/M), verified byte-equal.
   The light type-cast layer that was the other half of this item shipped with item 4 as the
   `transform.cast` node.
7. **Row operations:** DONE except rank -- `transform.limit` (top-N / bottom-N / row range),
   `transform.index`, `transform.replace`, `transform.fill` (down/up). **Rank still pending**
   (its cross-engine tie-ordering parity is the one fiddly bit).
8. **Designer column profiling:** DONE -- the preview panel shows filled / distinct / min /
   max per column over the loaded sample.
9. **Pipeline-level parameters:** DONE -- declare named parameters with defaults and bind
   `${Name}` tokens into input/output paths. PowerShell exposes them as function parameters
   (`Invoke-DataPipeline -InFile C:\june.csv`); the shell target exposes them as
   env-overridable vars (`PSPL_InFile=... ./pipeline.sh`). The engine resolves the tokens at
   run time. (Tokens anywhere in config work in PowerShell; the shell target restricts them
   to paths.)

## Explicitly out of scope

- **DAX and the interactive analytical model** -- measures, `CALCULATE`, evaluation
  context, relationships, time intelligence, KPIs.
- **The VertiPaq columnar engine**, ad-hoc pivot exploration, and report visuals.
- **Cloud/SaaS connectors and query folding.** Network egress is blocked in the target
  environment anyway, and the target users arrive with a CSV already in hand, so source
  connectivity is not a priority.

Rationale: these belong to the BI/analysis tool, not to a portable ETL script generator.
PSPipeline prepares the data; the user takes the clean output into Excel or Power BI --
and the M export above is the bridge that gets them there.
