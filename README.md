# PSPipeline

**A visual, drag-and-drop ETL pipeline designer that compiles to plain PowerShell.**

Draw a data flow — files in, transforms and joins in the middle, files out — the
way you would in Alteryx, Databricks, or DataStage. Then press one button and get
a single, self-contained PowerShell function that runs the whole pipeline on any
machine with PowerShell 5.1 or later. No agents, no licenses, no installs, no
admin rights.

```
 ┌─────────────┐
 │ customers   │──────────────┐
 │   .csv      │              ▼
 └─────────────┘         ┌──────────┐    ┌───────────┐    ┌──────┐    ┌────────────┐
 ┌─────────────┐         │   JOIN   │───▶│ AGGREGATE │───▶│ SORT │───▶│ report.csv │
 │ orders.csv  │──filter─▶│  (left)  │    │ sum/count │    └──────┘    └────────────┘
 └─────────────┘         └──────────┘    └───────────┘
                                  │
                                  ▼
                    Generate ▶  Invoke-DataPipeline.ps1   (runs anywhere PS 5.1+ runs)
```

## Why this exists

In locked-down enterprise environments, security controls rule out most data
tooling — but two things almost always survive:

1. **PowerShell is available** (it ships with Windows and is hard to remove), and
2. **people still need to extract, transform, and load data** (CSVs, tab-delimited
   extracts, JSON, fixed-width text) usually by hand, badly, in a spreadsheet.

The transform step is the gap. Real ETL platforms (Alteryx, Databricks,
DataStage) need licenses, installs, and network egress you won't get approved.
Power Query / M and DAX exist, but they sit beyond the digital-literacy line of
many of the people doing this work every day.

PSPipeline closes the gap with two pieces:

- **A visual designer** (`designer/index.html`) — a single HTML file that opens
  in any browser, fully offline. Drag files onto a canvas, snap transform nodes
  between them, wire up joins. If you can use a flowchart, you can use it.
- **A PowerShell engine + compiler** (`src/PSPipeline`) — runs pipeline
  definitions directly, or compiles them into a **standalone `.ps1` function
  with zero dependencies** that you can email to a colleague, drop on a file
  share, or schedule with Task Scheduler.

The designer is for building. The generated script is the product — and the
person running it just needs to know one command.

## Quick start

### 1. Design a pipeline

Open `designer/index.html` in a browser (no server needed). Drag a CSV file
onto the canvas, add transforms from the palette, click an output port then an
input port to connect nodes, and **Save JSON**.

Or skip the designer and start from `samples/sample-pipeline.json`.

### 2. Run it

```powershell
Import-Module .\src\PSPipeline\PSPipeline.psd1

# Run a pipeline definition directly (from the repo root):
Invoke-PSPipeline -Path .\samples\sample-pipeline.json -Verbose
# Writes samples\output\customer-order-summary.csv and returns the rows.
```

### 3. Compile it to a standalone script

```powershell
ConvertTo-PSPipelineScript -Path .\samples\sample-pipeline.json `
                           -OutputPath .\Invoke-DataPipeline.ps1

# On any other machine — no module, no internet, PowerShell 5.1+:
. .\Invoke-DataPipeline.ps1
Invoke-DataPipeline -BasePath C:\Data -Verbose
```

The generated script inlines the entire transform engine, embeds the pipeline
definition as JSON, and exposes exactly one function. That's the whole
deployment story.

## What it can do today

| Category | Nodes |
| --- | --- |
| **Inputs** | Delimited text (CSV, TSV, pipe, any delimiter, flat `.txt`), Fixed-width, JSON |
| **Column ops** | Select, Drop, Rename, Derived column (`{First} {Last}` templates), Conditional column (ordered if/then rules), Text (trim, case, extract before/after/between) |
| **Row ops** | Filter (eq, ne, gt, ge, lt, le, contains, startswith, endswith, isempty, isnotempty; All/Any), Sort, Distinct, Limit (top/bottom/range), Add index, Replace values, Fill down/up |
| **Combine** | **Join (Inner, Left, Right, Full outer)** (hash join, key-collision-safe), Union/Append (stack 2+ inputs, column-aligned), Aggregate (Count, Sum, Average, Min, Max, First, Median, CountDistinct, StringJoin with Group By) |
| **Dates / types** | Date (extract year/month/day/ISO-weekday, reformat, whole-day difference; ISO-ish `yyyy-MM-dd` input), Cast (text/number/integer) |
| **Reshape** | Unpivot (wide to long), Pivot (long to wide; PowerShell + M only, shell declines since its columns are data-dependent) |
| **Outputs** | Delimited text (any delimiter), JSON |

### Generate targets

The same pipeline compiles to any of these, picked from the designer's **Generate** menu:

| Target | Output | Runs on |
| --- | --- | --- |
| **PowerShell** | a standalone `.ps1` function with the engine inlined | Windows PowerShell 5.1+ / PowerShell 7+ |
| **POSIX shell** | a portable `sh` + `awk` script | any *nix with a POSIX `awk` |
| **Power Query M** | M code to paste into Excel / Power BI | Excel / Power BI |

A fourth engine, the **in-browser preview executor**, runs every node live in the designer so
you see each node's output on your own sample data before generating anything. PowerShell,
shell, and preview are verified byte-for-byte against each other on every node; the M export is
verified structurally, since it cannot be run without Excel. Where a target genuinely cannot
express a node it declines with a clear message rather than emit something subtly wrong (for
example, awk declines pivot because its output columns are data-dependent).

## Built for hostile environments

These are design constraints, not afterthoughts:

- **PowerShell 5.1 and up.** Everything runs on the Windows PowerShell that
  ships in the box, and on PowerShell 7+ identically.
- **Environment-aware.** `Get-PipelineEnvironment` detects the host at runtime
  (PS version/edition, OS, Constrained Language Mode) and the engine adapts.
  Delimited-text output is byte-identical across hosts (UTF-8 with BOM, so
  spreadsheets open it correctly), papering over the 5.1 vs 7+ encoding difference.
- **Constrained Language Mode friendly.** No `Add-Type`, no
  `Invoke-Expression`, no compiling user input into code — the derived-column
  node is a string template precisely so pipelines never execute arbitrary
  expressions.
- **No install, no admin, no network.** The designer is one HTML file; the
  generated script is one .ps1 file. `Import-Module` by path works from any
  folder the user can write to.

## Repository layout

```
PSPipeline/
├── designer/index.html           # visual designer — single file, open in a browser
├── src/PSPipeline/               # the PowerShell module
│   ├── PSPipeline.psd1 / .psm1
│   ├── Core/PipelineFunctions.ps1   # transforms + engine (inlined into generated scripts)
│   └── Public/                      # Invoke-PSPipeline, ConvertTo-PSPipelineScript
├── schemas/pipeline.schema.json  # the JSON contract between designer and engine
├── samples/                      # demo data + a working sample pipeline
├── tests/                        # Pester 5 tests
└── docs/architecture.md          # how the pieces fit, node config reference
```

## Roadmap

- [x] Core engine: inputs, column/row transforms, joins, aggregate, outputs
- [x] Environment detection and adaptive encoding behavior
- [x] Plain-text formats only: delimited text, fixed-width, JSON (Excel removed by design)
- [x] Standalone script generation (`ConvertTo-PSPipelineScript`)
- [x] Designer: palette, canvas, connections, properties, JSON round-trip
- [x] Data preview in the designer: live sample rows at every node (in-browser preview executor, verified against the PowerShell output) plus column-aware fields, via the browser File API
- [x] Friendly form builders for filter/sort/aggregate/rename and column pickers (no more JSON textareas, except the fixed-width column spec)
- [x] Designer quality-of-life: undo/redo (Ctrl+Z, Ctrl+Y / Ctrl+Shift+Z) and a read-only input path that the sample picker fills in
- [x] In-browser standalone script generation (the designer emits the zero-dependency `.ps1` directly)
- [x] Cross-platform code generation: a POSIX `sh` + `awk` backend alongside PowerShell (delimited + fixed-width input, all transforms, delimited output; JSON pending)
- [x] **M / Power Query export backend** (v1): the "Power Query M" Generate target compiles a pipeline to M for Excel / Power BI (all nodes except fixed-width input; columns export as text). The on-ramp to the Microsoft BI stack, not a rival.
- [x] **Power Query transform-parity track**: union/append, conditional column, text functions, date/time + type cast, pivot/unpivot, richer aggregations, row ops, column profiling — all shipped across the engines (awk declines pivot; dates work in awk via a self-implemented day-number)
- [x] Pipeline-level parameters: declare named params and bind `${Name}` into input/output paths; override at run time via PowerShell function params or shell env vars
- [ ] Parity tails still open: combine-a-folder-of-files, split-into-N-columns, rank aggregation

See **[docs/roadmap.md](docs/roadmap.md)** for the full roadmap, the M-export plan, the per-backend feasibility rule, and the explicit non-goals (DAX / interactive modeling stay out of scope).

## Running the tests (optional)

You do not need this to use PSPipeline — the designer and the generated scripts stand on
their own. The Pester suite is here only if you want to verify the engine yourself or are
contributing changes. It needs Pester 5:

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # once
Invoke-Pester -Path .\tests
```

## Contributing

See `docs/architecture.md` — especially the constraints on
`Core/PipelineFunctions.ps1` (it is inlined verbatim into every generated
script, so it must stay 5.1-compatible, dependency-free, and CLM-safe) and the
five-step checklist for adding a node type.

After cloning, enable the pre-commit hook so the single-file designer stays in
sync with its embedded sources automatically:

```sh
git config core.hooksPath .githooks
```

## License

MIT — see [LICENSE](LICENSE).
