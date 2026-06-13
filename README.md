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

## What it can do today (v0.1 stub)

| Category | Nodes |
| --- | --- |
| **Inputs** | Delimited text (CSV, TSV, pipe, any delimiter, flat `.txt`), Fixed-width, JSON |
| **Column ops** | Select, Drop, Rename, Derived column (`{First} {Last}` templates) |
| **Row ops** | Filter (eq, ne, gt, ge, lt, le, contains, startswith, endswith, isempty, isnotempty; All/Any), Sort, Distinct |
| **Combine** | **Join (Inner, Left, Right, Full outer)** (hash join, key-collision-safe), Aggregate (Count, Sum, Average, Min, Max, First with Group By) |
| **Outputs** | Delimited text (any delimiter), JSON |

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
- [ ] **M / Power Query export backend** (next priority): compile a pipeline to Power Query M so users can take it into Excel / Power BI (the on-ramp to the Microsoft BI stack, not a rival to it)
- [ ] **Power Query transform-parity track**: union/append (incl. folder-of-files), conditional column, text & date functions, pivot/unpivot, type casting, richer aggregations, row ops, column profiling
- [ ] Pipeline-level parameters (e.g. input path prompts at run time)
- [ ] PowerShell Gallery publication
- [ ] _Parked / undecided_: PowerShell 7+ parallel target (`ForEach-Object -Parallel` over independent DAG branches). Deprioritized in favor of the M work; may revisit later.

See **[docs/roadmap.md](docs/roadmap.md)** for the full roadmap, the M-export plan, the per-backend feasibility rule, and the explicit non-goals (DAX / interactive modeling stay out of scope).

## Running the tests

```powershell
Install-Module Pester -MinimumVersion 5.0 -Scope CurrentUser   # once
Invoke-Pester -Path .\tests
```

## Contributing

See `docs/architecture.md` — especially the constraints on
`Core/PipelineFunctions.ps1` (it is inlined verbatim into every generated
script, so it must stay 5.1-compatible, dependency-free, and CLM-safe) and the
five-step checklist for adding a node type.

## License

MIT — see [LICENSE](LICENSE).
