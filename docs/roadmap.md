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

In progress:
5. PowerShell 7+ parallel target (`ForEach-Object -Parallel` over independent DAG branches; opt-in, order-preserving).

## Design rule for everything below

Every transform node must be implementable across the code-generation backends
(PowerShell, POSIX `sh`+`awk`, and the planned M export) and the in-browser preview
executor (`tools/samplerun.js`) -- or be explicitly marked target-specific. Adding a node
is therefore N implementations, not one. Some transforms (pivot, window functions) are
cheap in M and PowerShell but hard in POSIX awk; where that is true, the awk backend may
decline that node with a clear message rather than emit something subtly wrong. Track
feasibility per node, per backend.

## Planned: M / Power Query export (a gateway, not a competitor)

Add an `mquery` backend that compiles a pipeline to Power Query **M code** the user can
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

1. **Union / append**, including combine-all-files-in-a-folder. The single most common
   real task ("merge the 12 monthly extracts"). Highest value.
2. **Conditional column (if/then/else).** The biggest expressiveness gap today, since
   `derive` is only a string template. Implement as a structured ordered-rules node
   (condition -> value), not arbitrary code, to stay CLM-safe.
3. **Text functions:** split (by delimiter/position), extract (before/after/between),
   trim/clean, change case, merge columns.
4. **Date/time functions** + a light type layer: parse, format, extract
   (year/month/day/weekday), difference. Turns "reshape" into "actually clean."
5. **Pivot / unpivot** (long <-> wide). Common in reporting. (Hard in awk; likely starts
   PowerShell- and M-only.)
6. **Type casting** + richer aggregations: count-distinct, median/percentile, string-join
   (group-and-concatenate).
7. **Row operations:** keep top-N / bottom-N / row range, add index, rank; replace values;
   fill down/up.
8. **Designer column profiling:** null counts, distinct counts, min/max/sample in the
   preview panel. Cheap, high perceived polish.
9. **Pipeline-level parameters:** prompt for input/output paths (or values) at run time in
   the generated script.

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
