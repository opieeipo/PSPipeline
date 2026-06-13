# PSPipeline roadmap

PSPipeline reproduces a focused subset of Power Query / M (file-based ETL) in a form
that runs in locked-down environments: no installs, no admin, no network, Constrained
Language Mode safe, compiled to a single portable script. This document captures where
it is and where it is going, and -- just as importantly -- what it will deliberately
never do.

## Status

Done:
1. Plain-text format scope (delimited, fixed-width, JSON; Excel and XML deliberately excluded).
2. Backend interface + in-browser PowerShell generation (the designer emits a zero-dependency `.ps1`).
3. POSIX `sh` + `awk` backend for *nix.
4. Designer data preview: schema-aware column propagation, live per-node row preview, column-aware field builders, undo/redo, read-only input path.

Next up (in priority order):
- M / Power Query export backend (see below) -- the current top priority.
- The Power Query transform-parity track (see below).

Parked / undecided:
- PowerShell 7+ parallel target (`ForEach-Object -Parallel` over independent DAG branches; opt-in, order-preserving). Deprioritized in favor of the M work. May revisit if a large-data, less-restricted use case arises and a PowerShell 7 verification environment is available. Not committed.

## Design rule for everything below

Every transform node must be implementable across the code-generation backends
(PowerShell, POSIX `sh`+`awk`, and the planned M export) and the in-browser preview
executor (`tools/samplerun.js`) -- or be explicitly marked target-specific. Adding a node
is therefore N implementations, not one. Some transforms (pivot, window functions) are
cheap in M and PowerShell but hard in POSIX awk; where that is true, the awk backend may
decline that node with a clear message rather than emit something subtly wrong. Track
feasibility per node, per backend.

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
| `transform.derive` | `Table.AddColumn` |
| `transform.filter` | `Table.SelectRows` |
| `transform.sort` | `Table.Sort` |
| `transform.distinct` | `Table.Distinct` |
| `transform.join` | `Table.NestedJoin` + `Table.ExpandTableColumn` |
| `transform.aggregate` | `Table.Group` |

Multi-input DAGs (joins) map to multiple `let` queries. A bonus: emitting M is a
third-party validation of our pipeline semantics.

## Planned: transform parity with Power Query (the "M-gaps")

Ordered by value to the target persona (non-IT people doing extract/clean work in
locked-down shops). None of these requires breaking the no-install / CLM-safe / portable
constraints.

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
   **Type casting still pending** (a light number/date normalize node, mainly useful for the
   M export's typing).
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

### Level of effort and sequencing

LOE is driven less by transform logic (most is simple) than by a structural tax: each new
node is implemented in **three engines** (PowerShell, awk via `shellgen.js`, and the
`samplerun.js` preview) plus the designer node, schema, `outputColumns` propagation, and
tests -- and **four** once the M backend exists. Sizes below are for a focused dev who knows
this codebase, relative to the phases already shipped (S = a fraction of a session, M = about
half to one session, L = one or more sessions).

| # | Item | Size | Main cost / risk | awk feasibility |
|---|------|------|------------------|-----------------|
| 1 | Union / append (+ folder) | M-L | New **variable-arity input ports** in the designer (canvas/connection infra; ports are fixed today). Folder = multi-file read. | OK (header-union); folder = shell loop |
| 2 | Conditional column | M | A **nested rules-builder UI** (conditions inside rules); logic reuses existing condition eval. | OK (reuse `condExpr`) |
| 3 | Text functions | M-L (group) | Many small nodes; **split-into-N-columns** has a data-dependent column count. | OK |
| 4 | Date/time + light type layer | L | **Cross-engine date-format parity is the hardest correctness problem in the track**; type layer is cross-cutting. | Hard (no POSIX date) -> likely PS + M only |
| 5 | Pivot / unpivot | M (unpivot) + L (pivot) | Pivot output columns are **data-dependent** (runtime discovery). | unpivot OK; pivot hard -> PS + M only |
| 6 | Type cast + richer aggregations | M | median/percentile need in-group sort; mostly extends the aggregate node. | moderate |
| 7 | Row operations | M (a bag of S's) | Each is small/easy; volume is the cost. | OK |
| 8 | Designer column profiling | S-M | Designer/preview only, **no backend codegen**. | n/a |
| 9 | Pipeline-level parameters | M | Cross-cutting: every backend's wrapper + a designer binding UI. | moderate |

Two things that change the math:

- **The M backend is a verification cliff.** M output cannot be runtime-verified in this
  environment (no Excel / Power Query engine), exactly like the parked PS7 target. PowerShell,
  awk, and preview get diffed against the oracle; M can only be syntax-shaped until it is run
  in Excel/Power BI. Do not couple parity tightly to M before accepting that.
- **Data-dependent columns** (split-into-N, pivot) are the recurring hard case: when output
  columns depend on the data, static schema propagation and the downstream column-aware
  dropdowns degrade, and the backends must discover columns at runtime.

Suggested sequencing by value-to-effort:

- **Quick wins first:** #8 profiling (designer-only), the trim/case/clean subset of #3, and
  #7 row ops.
- **High value, do the infra once:** #1 union/append (the variable-arity-port work unblocks
  all future multi-input nodes), then #2 conditional column.
- **Defer / treat as their own mini-projects:** #4 dates+types and #5 pivot; #9 parameters is
  orthogonal and can land anytime.

Rollup: the full track roughly doubles the node count across multiple backends, so in total
it is on the order of everything built so far -- about **6-10 focused sessions** at current
pace, but cleanly phaseable and front-loadable with the quick wins. The single highest-leverage
first slice is **union/append plus the variable-arity port infrastructure**.

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
