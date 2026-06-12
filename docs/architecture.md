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
between the layers. The designer reads and writes that JSON and compiles it to
scripts; the engine executes it. Either side can be replaced independently.

### Designer schema awareness and preview

The designer computes the column list at every node directly from the graph: input headers
(from a sample file loaded via the File API, or from a fixed-width node's column spec)
propagated through each transform's known effect on columns (select keeps, join concatenates
with a `Right_` prefix on collisions, aggregate emits group-by + aggregation names, and so on).
That powers the column-aware dropdowns and builders.

For row preview, `tools/samplerun.js` runs the loaded sample rows through the DAG so resulting
rows show at every node (transforms and outputs), not just inputs. It is a *third* implementation
of the transform semantics, alongside the PowerShell engine and the awk runtime, used ONLY for
preview -- so it carries the same drift risk and is verified byte-for-byte against the PowerShell
output on the sample pipeline. Loaded sample data is never written into the pipeline JSON.

## Code generation backends

A *backend* turns a pipeline definition into a finished, self-contained script for
one runtime. The pipeline JSON is language-neutral, so backends are independent and
additive. One exists; one is planned:

| Backend | Target | Where it lives | Status |
| --- | --- | --- | --- |
| PowerShell | Windows PowerShell 5.1+ / 7+ | `designer/index.html` (`BACKENDS.powershell`) and the CLI cmdlet `ConvertTo-PSPipelineScript` | done |
| Shell | POSIX `sh` + `awk` for *nix | `designer/index.html` (`BACKENDS.shell`) | done for delimited + fixed-width input, all transforms, delimited output; JSON nodes pending |

The browser is the primary generation surface: the target users build pipelines
there and need a runnable artifact without ever touching PowerShell. So the canonical
backend registry is the JS `BACKENDS` object in the designer, each entry exposing
`{ label, ext, available, filename(def), generate(def) }`.

For the backends to emit from the browser, their runnable sources are embedded in
`designer/index.html` and injected by `tools/Sync-DesignerEngine.ps1`, which must be
re-run whenever any of them change:

| Source | Embedded as | Used by |
| --- | --- | --- |
| `Core/PipelineFunctions.ps1` | `#ps-engine-source` (inlined verbatim) | PowerShell backend |
| `Core/pipeline-runtime.sh` | `#sh-runtime-source` (the awk runtime, the *nix analog of the engine) | Shell backend |
| `tools/shellgen.js` | `#shellgen-source` (the DAG-to-awk compiler) | Shell backend |
| `tools/samplerun.js` | `#samplerun-source` (the in-browser preview executor) | Designer row preview |

    pwsh -File tools/Sync-DesignerEngine.ps1

The CLI cmdlet `ConvertTo-PSPipelineScript` is the PowerShell backend implemented
server-side (it reads the engine file directly rather than from an embedded copy) and
produces an equivalent artifact. There is no CLI for the shell target yet; generate it
from the browser.

### Shell backend specifics

Unlike the PowerShell backend (which inlines a JSON-interpreting engine), the shell
backend does straight-line compilation: it walks the topologically-sorted DAG and emits
one `awk` step per node, chaining through unit-separator-delimited temp files. Intentional
differences from the PowerShell output, all verified against it on the sample pipeline:

- Output uses LF line endings and no UTF-8 BOM (the *nix convention), where the PowerShell
  backend writes CRLF with a BOM.
- String comparisons (filter, sort, distinct) are case-insensitive to match PowerShell's
  `-eq`/`-lt`/`-like` and `Sort-Object` defaults.
- Not yet supported in the shell target: JSON input/output, and CSV fields containing
  embedded newlines (single-line RFC-4180 quoting is handled). A JSON node makes generation
  fail with a clear message rather than emit a broken script.

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
| `PSVersion` / `PSEdition` | 5.1 vs 7+ behavior differences (e.g. UTF-8 BOM on delimited-text export) |
| `IsWindows` | `$IsWindows` doesn't exist on 5.1; its absence implies Windows |
| `LanguageMode` / `IsConstrained` | Constrained Language Mode is why nodes never compile or eval user input |
| `Utf8WritesBom` | Delimited-text output is byte-identical (BOM included) on every host |

## Node config shapes

| Node type | `config` |
| --- | --- |
| `input.csv` (delimited text) | `{ path, delimiter? }` |
| `input.fixedwidth` | `{ path, columns: [{ name, start, length }], skipLines? }` |
| `input.json` | `{ path }` |
| `transform.select` / `drop` | `{ columns: [] }` |
| `transform.rename` | `{ renames: [{ from, to }] }` |
| `transform.derive` | `{ name, template }` — `{Column}` placeholders, no code eval |
| `transform.filter` | `{ match: All\|Any, conditions: [{ column, operator, value }] }` |
| `transform.sort` | `{ sortBy: [{ column, descending? }] }` |
| `transform.distinct` | `{ columns?: [] }` |
| `transform.join` | `{ joinType: Inner\|Left\|Right\|Full, leftKey, rightKey }` |
| `transform.aggregate` | `{ groupBy: [], aggregations: [{ column, function, as? }] }` |
| `output.csv` / `json` | `{ path, delimiter? }` |

## Locked-down-environment constraints

Everything in `Core/PipelineFunctions.ps1` must remain:

- **PowerShell 5.1 compatible** — no PS7-only syntax, parameters, or operators.
- **Dependency-free** -- built-in cmdlets only, no external modules.
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
