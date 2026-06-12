# PSPipeline architecture

## The three layers

```
┌──────────────────────────┐     ┌──────────────────────────┐     ┌──────────────────────────┐
│  designer/index.html     │     │  pipeline.json           │     │  Invoke-DataPipeline.ps1 │
│  visual editor (browser, │ ──▶ │  portable definition     │ ──▶ │  self-contained PS 5.1+  │
│  zero install, offline)  │     │  (the contract)          │     │  script (the product)    │
└──────────────────────────┘     └──────────────────────────┘     └──────────────────────────┘
                                          │
                                          ▼
                                 Invoke-PSPipeline (module)
                                 runs definitions directly
```

The **pipeline definition JSON** (`schemas/pipeline.schema.json`) is the contract
between the layers. The designer only reads/writes JSON; the engine only executes
JSON. Either side can be replaced independently (e.g. a WPF designer later).

## Execution model

A pipeline is a DAG of nodes connected by edges. Each edge feeds a named input
port on the destination node (`in` for most nodes, `left`/`right` for joins).
`Invoke-PipelineDefinition`:

1. Calls `Assert-PipelineHost` (version gate + environment banner via `-Verbose`).
2. Topologically sorts the graph (Kahn's algorithm; cycles are an error).
3. Executes nodes in order, caching each node's row set by node id.
4. Returns a dictionary of leaf-node results keyed by node id. Output nodes
   write files as a side effect and pass their rows through, so they can be
   chained or inspected.

Rows are arrays of `PSCustomObject` throughout — the same shape `Import-Csv`
produces — so every node composes with ordinary PowerShell.

## Environment awareness

`Get-PipelineEnvironment` (cached, refresh with `-Refresh`) detects:

| Property | Use |
| --- | --- |
| `PSVersion` / `PSEdition` | 5.1 vs 7+ behavior differences (e.g. UTF-8 BOM on CSV export) |
| `IsWindows` | `$IsWindows` doesn't exist on 5.1; its absence implies Windows |
| `LanguageMode` / `IsConstrained` | Constrained Language Mode disables COM fallback |
| `HasImportExcel` / `HasExcelCom` / `ExcelSupport` | Excel nodes pick `ImportExcel` → COM → clear error, in that order |
| `Utf8WritesBom` | CSV output is byte-identical (BOM included) on every host |

## Node config shapes

| Node type | `config` |
| --- | --- |
| `input.csv` | `{ path, delimiter? }` |
| `input.json` | `{ path }` |
| `input.excel` | `{ path, worksheet? }` |
| `transform.select` / `drop` | `{ columns: [] }` |
| `transform.rename` | `{ renames: [{ from, to }] }` |
| `transform.derive` | `{ name, template }` — `{Column}` placeholders, no code eval |
| `transform.filter` | `{ match: All\|Any, conditions: [{ column, operator, value }] }` |
| `transform.sort` | `{ sortBy: [{ column, descending? }] }` |
| `transform.distinct` | `{ columns?: [] }` |
| `transform.join` | `{ joinType: Inner\|Left\|Right\|Full, leftKey, rightKey }` |
| `transform.aggregate` | `{ groupBy: [], aggregations: [{ column, function, as? }] }` |
| `output.csv` / `json` / `excel` | `{ path, delimiter? / worksheet? }` |

## Locked-down-environment constraints

Everything in `Core/PipelineFunctions.ps1` must remain:

- **PowerShell 5.1 compatible** — no PS7-only syntax, parameters, or operators.
- **Dependency-free** — built-in cmdlets only; ImportExcel is opportunistic.
- **CLM-friendly** — no `Add-Type`, no `Invoke-Expression`, no scriptblock
  creation from user strings. The derived-column node is a string template,
  not an expression evaluator, for exactly this reason.
- **Single-file** — `ConvertTo-PSPipelineScript` inlines the file verbatim into
  generated scripts; splitting it breaks code generation.

## Adding a node type (checklist)

1. Implement the transform function in `Core/PipelineFunctions.ps1`.
2. Add a case to `Invoke-PipelineNode`'s `switch`.
3. Add the type to `schemas/pipeline.schema.json`.
4. Add a `NODE_TYPES` entry in `designer/index.html` (palette, ports, fields).
5. Add a Pester test in `tests/`.
