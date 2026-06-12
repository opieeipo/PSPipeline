#region PSPipeline core functions
# ---------------------------------------------------------------------------
# This file is shared between the PSPipeline module AND every generated
# standalone script (ConvertTo-PSPipelineScript inlines it verbatim).
#
# Hard constraints for everything in this file:
#   * Windows PowerShell 5.1 compatible (no PS7-only syntax or parameters)
#   * Built-in cmdlets only — no required external modules (ImportExcel is
#     used opportunistically for .xlsx and degrades with a clear error)
#   * Constrained Language Mode friendly: no Add-Type, no Invoke-Expression,
#     no [scriptblock]::Create on user-supplied strings
# ---------------------------------------------------------------------------

# --- Environment awareness --------------------------------------------------

$script:PipelineEnvironment = $null

function Get-PipelineEnvironment {
    <#
    .SYNOPSIS
        Detects the capabilities of the current host so pipeline nodes can
        adapt to the environment they are running in. Result is cached.
    .OUTPUTS
        PSCustomObject with version, edition, OS, language mode and Excel
        support information.
    #>
    param([switch]$Refresh)
    if ($script:PipelineEnvironment -and -not $Refresh) { return $script:PipelineEnvironment }

    $psVersion = $PSVersionTable.PSVersion
    $edition   = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }

    # $IsWindows does not exist in Windows PowerShell 5.1 — its absence means Windows.
    $isWindowsHost = if ($null -eq (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $true } else { [bool]$IsWindows }

    $languageMode  = [string]$ExecutionContext.SessionState.LanguageMode
    $isConstrained = $languageMode -ne 'FullLanguage'

    $hasImportExcel = $null -ne (Get-Module -ListAvailable -Name ImportExcel -ErrorAction SilentlyContinue | Select-Object -First 1)
    # COM is only usable on Windows, with Excel registered, outside Constrained Language Mode.
    $hasExcelCom = $isWindowsHost -and -not $isConstrained -and
                   (Test-Path -Path 'Registry::HKEY_CLASSES_ROOT\Excel.Application')

    $script:PipelineEnvironment = [pscustomobject]@{
        PSVersion      = $psVersion
        PSEdition      = $edition
        IsWindows      = $isWindowsHost
        LanguageMode   = $languageMode
        IsConstrained  = $isConstrained
        HasImportExcel = $hasImportExcel
        HasExcelCom    = $hasExcelCom
        ExcelSupport   = if ($hasImportExcel) { 'ImportExcel' } elseif ($hasExcelCom) { 'Com' } else { 'None' }
        # Windows PowerShell 5.1 writes a UTF-8 BOM with -Encoding UTF8; PowerShell 6+
        # does not unless asked. Used to keep CSV output Excel-friendly on every host.
        Utf8WritesBom  = $psVersion.Major -le 5
    }
    $script:PipelineEnvironment
}

function Assert-PipelineHost {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PSPipeline requires Windows PowerShell 5.1 or later (detected $($PSVersionTable.PSVersion))."
    }
    $environment = Get-PipelineEnvironment
    Write-Verbose ("PSPipeline host: PowerShell {0} ({1}), {2}, LanguageMode={3}, ExcelSupport={4}" -f `
        $environment.PSVersion, $environment.PSEdition,
        $(if ($environment.IsWindows) { 'Windows' } else { 'Non-Windows' }),
        $environment.LanguageMode, $environment.ExcelSupport)
}

# --- Input nodes -----------------------------------------------------------

function Import-PipelineCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Delimiter = ','
    )
    @(Import-Csv -Path $Path -Delimiter $Delimiter)
}

function Import-PipelineJson {
    param([Parameter(Mandatory)][string]$Path)
    $data = Get-Content -Path $Path -Raw | ConvertFrom-Json
    @($data)
}

function Import-PipelineExcelCom {
    # Fallback reader for hosts that have Excel installed but cannot install
    # modules. Requires FullLanguage mode (COM is blocked under CLM).
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Worksheet
    )
    $excel = $null
    $workbook = $null
    try {
        $excel = New-Object -ComObject Excel.Application
        $excel.Visible = $false
        $excel.DisplayAlerts = $false
        $workbook = $excel.Workbooks.Open((Resolve-Path -Path $Path).Path, 0, $true) # read-only
        $sheet = if ($Worksheet) { $workbook.Worksheets.Item($Worksheet) } else { $workbook.Worksheets.Item(1) }
        $range = $sheet.UsedRange
        $rowCount = $range.Rows.Count
        $columnCount = $range.Columns.Count
        if ($rowCount -lt 2) { return @() }
        $values = $range.Value2  # 2-D array indexed [1..rows, 1..cols]
        $headers = @(for ($c = 1; $c -le $columnCount; $c++) { [string]$values[1, $c] })
        @(for ($r = 2; $r -le $rowCount; $r++) {
            $out = [ordered]@{}
            for ($c = 1; $c -le $columnCount; $c++) { $out[$headers[$c - 1]] = $values[$r, $c] }
            [pscustomobject]$out
        })
    }
    finally {
        if ($workbook) { $workbook.Close($false) }
        if ($excel) {
            $excel.Quit()
            [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
        }
    }
}

function Import-PipelineExcel {
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Worksheet
    )
    $environment = Get-PipelineEnvironment
    switch ($environment.ExcelSupport) {
        'ImportExcel' {
            if ($Worksheet) { @(Import-Excel -Path $Path -WorksheetName $Worksheet) }
            else { @(Import-Excel -Path $Path) }
        }
        'Com' { Import-PipelineExcelCom -Path $Path -Worksheet $Worksheet }
        default {
            throw "This host has no Excel support: the ImportExcel module is not installed and Excel COM is unavailable (LanguageMode=$($environment.LanguageMode)). Workarounds: 'Install-Module ImportExcel -Scope CurrentUser', or save the worksheet as CSV and use a CSV input node."
        }
    }
}

# --- Column transforms -----------------------------------------------------

function Select-PipelineColumn {
    param([object[]]$Data, [string[]]$Columns)
    @($Data | Select-Object -Property $Columns)
}

function Remove-PipelineColumn {
    param([object[]]$Data, [string[]]$Columns)
    @($Data | Select-Object -Property * -ExcludeProperty $Columns)
}

function Rename-PipelineColumn {
    # $Renames is an array of objects with .from and .to (shape matches the JSON definition)
    param([object[]]$Data, [object[]]$Renames)
    $map = @{}
    foreach ($r in $Renames) { $map[[string]$r.from] = [string]$r.to }
    @(foreach ($row in $Data) {
        $out = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) {
            $name = if ($map.ContainsKey($prop.Name)) { $map[$prop.Name] } else { $prop.Name }
            $out[$name] = $prop.Value
        }
        [pscustomobject]$out
    })
}

function Add-PipelineColumn {
    # Adds a derived column from a template string with {ColumnName} placeholders,
    # e.g. -Name FullName -Template '{FirstName} {LastName}'.
    # Deliberately not an expression evaluator: no code execution, CLM-safe.
    param(
        [object[]]$Data,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Template
    )
    @(foreach ($row in $Data) {
        $out = [ordered]@{}
        $value = $Template
        foreach ($prop in $row.PSObject.Properties) {
            $out[$prop.Name] = $prop.Value
            $value = $value.Replace('{' + $prop.Name + '}', [string]$prop.Value)
        }
        $out[$Name] = $value
        [pscustomobject]$out
    })
}

# --- Row transforms --------------------------------------------------------

function Test-PipelineCondition {
    # $Condition has .column, .operator, .value
    param($Row, $Condition)
    $actual = $Row.($Condition.column)
    $expected = $Condition.value

    # Compare numerically when both sides parse as numbers, otherwise as strings.
    $actualNum = 0.0; $expectedNum = 0.0
    $isNumeric = [double]::TryParse([string]$actual, [ref]$actualNum) -and
                 [double]::TryParse([string]$expected, [ref]$expectedNum)

    switch ([string]$Condition.operator) {
        'eq'         { if ($isNumeric) { $actualNum -eq $expectedNum } else { [string]$actual -eq [string]$expected } }
        'ne'         { if ($isNumeric) { $actualNum -ne $expectedNum } else { [string]$actual -ne [string]$expected } }
        'gt'         { if ($isNumeric) { $actualNum -gt $expectedNum } else { [string]$actual -gt [string]$expected } }
        'ge'         { if ($isNumeric) { $actualNum -ge $expectedNum } else { [string]$actual -ge [string]$expected } }
        'lt'         { if ($isNumeric) { $actualNum -lt $expectedNum } else { [string]$actual -lt [string]$expected } }
        'le'         { if ($isNumeric) { $actualNum -le $expectedNum } else { [string]$actual -le [string]$expected } }
        'contains'   { [string]$actual -like ('*' + [string]$expected + '*') }
        'startswith' { [string]$actual -like ([string]$expected + '*') }
        'endswith'   { [string]$actual -like ('*' + [string]$expected) }
        'isempty'    { $null -eq $actual -or [string]$actual -eq '' }
        'isnotempty' { $null -ne $actual -and [string]$actual -ne '' }
        default      { throw "Unknown filter operator '$($Condition.operator)'." }
    }
}

function Where-PipelineRow {
    param(
        [object[]]$Data,
        [object[]]$Conditions,
        [ValidateSet('All', 'Any')][string]$Match = 'All'
    )
    @(foreach ($row in $Data) {
        $passes = @(foreach ($c in $Conditions) { Test-PipelineCondition -Row $row -Condition $c })
        $keep = if ($Match -eq 'All') { $passes -notcontains $false } else { $passes -contains $true }
        if ($keep) { $row }
    })
}

function Sort-PipelineData {
    # $SortBy is an array of objects with .column and optional .descending
    param([object[]]$Data, [object[]]$SortBy)
    $properties = @(foreach ($s in $SortBy) {
        @{ Expression = [string]$s.column; Descending = [bool]$s.descending }
    })
    @($Data | Sort-Object -Property $properties)
}

function Select-PipelineDistinct {
    param([object[]]$Data, [string[]]$Columns)
    if ($Columns -and $Columns.Count -gt 0) {
        return @($Data | Sort-Object -Property $Columns -Unique)
    }
    @($Data | Sort-Object -Property * -Unique)
}

# --- Join ------------------------------------------------------------------

function Merge-PipelineRow {
    # Combines one left row and one right row into a single flat row.
    # Right-side columns that collide with left-side names get a 'Right_' prefix.
    param($LeftRow, $RightRow, [string[]]$LeftColumns, [string[]]$RightColumns)
    $out = [ordered]@{}
    foreach ($c in $LeftColumns) {
        $out[$c] = if ($null -ne $LeftRow) { $LeftRow.$c } else { $null }
    }
    foreach ($c in $RightColumns) {
        $name = if ($out.Contains($c)) { 'Right_' + $c } else { $c }
        $out[$name] = if ($null -ne $RightRow) { $RightRow.$c } else { $null }
    }
    [pscustomobject]$out
}

function Join-PipelineData {
    param(
        [object[]]$Left,
        [object[]]$Right,
        [Parameter(Mandatory)][string]$LeftKey,
        [Parameter(Mandatory)][string]$RightKey,
        [ValidateSet('Inner', 'Left', 'Right', 'Full')][string]$JoinType = 'Inner'
    )
    $leftColumns  = if ($Left.Count)  { @($Left[0].PSObject.Properties.Name) }  else { @() }
    $rightColumns = if ($Right.Count) { @($Right[0].PSObject.Properties.Name) } else { @() }

    # Index the right side by key for O(n + m) matching.
    $rightIndex = @{}
    foreach ($row in $Right) {
        $key = [string]$row.$RightKey
        if (-not $rightIndex.ContainsKey($key)) {
            $rightIndex[$key] = New-Object System.Collections.ArrayList
        }
        [void]$rightIndex[$key].Add($row)
    }

    $results = New-Object System.Collections.ArrayList
    $matchedKeys = @{}
    foreach ($leftRow in $Left) {
        $key = [string]$leftRow.$LeftKey
        if ($rightIndex.ContainsKey($key)) {
            $matchedKeys[$key] = $true
            foreach ($rightRow in $rightIndex[$key]) {
                [void]$results.Add((Merge-PipelineRow $leftRow $rightRow $leftColumns $rightColumns))
            }
        }
        elseif ($JoinType -eq 'Left' -or $JoinType -eq 'Full') {
            [void]$results.Add((Merge-PipelineRow $leftRow $null $leftColumns $rightColumns))
        }
    }
    if ($JoinType -eq 'Right' -or $JoinType -eq 'Full') {
        foreach ($rightRow in $Right) {
            if (-not $matchedKeys.ContainsKey([string]$rightRow.$RightKey)) {
                [void]$results.Add((Merge-PipelineRow $null $rightRow $leftColumns $rightColumns))
            }
        }
    }
    @($results)
}

# --- Aggregate -------------------------------------------------------------

function Group-PipelineData {
    # $Aggregations is an array of objects with .column, .function and optional .as
    # Functions: Count, Sum, Average, Min, Max, First
    param(
        [object[]]$Data,
        [string[]]$GroupBy,
        [object[]]$Aggregations
    )
    @(foreach ($group in ($Data | Group-Object -Property $GroupBy)) {
        $out = [ordered]@{}
        $first = $group.Group[0]
        foreach ($col in $GroupBy) { $out[$col] = $first.$col }
        foreach ($agg in $Aggregations) {
            $name = if ($agg.as) { [string]$agg.as } else { '{0}_{1}' -f $agg.function, $agg.column }
            $out[$name] = switch ([string]$agg.function) {
                'Count' { $group.Count }
                'First' { $first.($agg.column) }
                default {
                    # Numeric aggregations: ignore rows where the value doesn't parse
                    # (e.g. nulls introduced by an outer join).
                    $numbers = @(foreach ($row in $group.Group) {
                        $n = 0.0
                        if ([double]::TryParse([string]$row.($agg.column), [ref]$n)) { $n }
                    })
                    switch ([string]$agg.function) {
                        'Sum'     { ($numbers | Measure-Object -Sum).Sum }
                        'Average' { ($numbers | Measure-Object -Average).Average }
                        'Min'     { ($numbers | Measure-Object -Minimum).Minimum }
                        'Max'     { ($numbers | Measure-Object -Maximum).Maximum }
                        default   { throw "Unknown aggregate function '$($agg.function)'." }
                    }
                }
            }
        }
        [pscustomobject]$out
    })
}

# --- Output nodes ----------------------------------------------------------

function Assert-PipelineOutputDirectory {
    param([string]$Path)
    $directory = Split-Path -Path $Path -Parent
    if ($directory -and -not (Test-Path -Path $directory)) {
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
    }
}

function Export-PipelineCsv {
    param([object[]]$Data, [Parameter(Mandatory)][string]$Path, [string]$Delimiter = ',')
    Assert-PipelineOutputDirectory -Path $Path
    # Keep output identical across hosts: 5.1's UTF8 already includes a BOM
    # (which Excel expects); PowerShell 6+ needs to be asked for one.
    $encoding = if ((Get-PipelineEnvironment).Utf8WritesBom) { 'UTF8' } else { 'utf8BOM' }
    $Data | Export-Csv -Path $Path -NoTypeInformation -Delimiter $Delimiter -Encoding $encoding
}

function Export-PipelineJson {
    param([object[]]$Data, [Parameter(Mandatory)][string]$Path)
    Assert-PipelineOutputDirectory -Path $Path
    ConvertTo-Json -InputObject $Data -Depth 10 | Set-Content -Path $Path -Encoding UTF8
}

function Export-PipelineExcel {
    param([object[]]$Data, [Parameter(Mandatory)][string]$Path, [string]$Worksheet = 'Sheet1')
    $environment = Get-PipelineEnvironment
    if ($environment.HasImportExcel) {
        Assert-PipelineOutputDirectory -Path $Path
        $Data | Export-Excel -Path $Path -WorksheetName $Worksheet
        return
    }
    # TODO(stub): Excel COM writer fallback for module-less Windows hosts
    throw "Excel output on this host requires the ImportExcel module (Install-Module ImportExcel -Scope CurrentUser). Workaround: use a CSV output node (ExcelSupport=$($environment.ExcelSupport))."
}

# --- Execution engine ------------------------------------------------------

function Get-PipelineExecutionOrder {
    # Topological sort (Kahn's algorithm) over the node graph.
    param([Parameter(Mandatory)]$Definition)
    $incoming = @{}
    $adjacent = @{}
    foreach ($node in $Definition.nodes) {
        $incoming[$node.id] = 0
        $adjacent[$node.id] = New-Object System.Collections.ArrayList
    }
    foreach ($edge in @($Definition.edges)) {
        if (-not $incoming.ContainsKey($edge.to) -or -not $adjacent.ContainsKey($edge.from)) {
            throw "Edge '$($edge.from)' -> '$($edge.to)' references a node that does not exist."
        }
        $incoming[$edge.to] = $incoming[$edge.to] + 1
        [void]$adjacent[$edge.from].Add($edge.to)
    }
    $queue = New-Object System.Collections.Queue
    foreach ($node in $Definition.nodes) {
        if ($incoming[$node.id] -eq 0) { $queue.Enqueue($node.id) }
    }
    $order = New-Object System.Collections.ArrayList
    while ($queue.Count -gt 0) {
        $id = $queue.Dequeue()
        [void]$order.Add($id)
        foreach ($next in $adjacent[$id]) {
            $incoming[$next] = $incoming[$next] - 1
            if ($incoming[$next] -eq 0) { $queue.Enqueue($next) }
        }
    }
    if ($order.Count -ne @($Definition.nodes).Count) {
        throw 'Pipeline definition contains a cycle and cannot be executed.'
    }
    @($order)
}

function Invoke-PipelineNode {
    # $Inputs maps input port name ('in', 'left', 'right') to that port's data.
    param(
        [Parameter(Mandatory)]$Node,
        [hashtable]$Inputs
    )
    $config = $Node.config
    switch ([string]$Node.type) {
        'input.csv'    { Import-PipelineCsv -Path $config.path -Delimiter $(if ($config.delimiter) { $config.delimiter } else { ',' }) }
        'input.json'   { Import-PipelineJson -Path $config.path }
        'input.excel'  { Import-PipelineExcel -Path $config.path -Worksheet $config.worksheet }

        'transform.select'    { Select-PipelineColumn -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.drop'      { Remove-PipelineColumn -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.rename'    { Rename-PipelineColumn -Data $Inputs['in'] -Renames @($config.renames) }
        'transform.derive'    { Add-PipelineColumn -Data $Inputs['in'] -Name $config.name -Template $config.template }
        'transform.filter'    { Where-PipelineRow -Data $Inputs['in'] -Conditions @($config.conditions) -Match $(if ($config.match) { $config.match } else { 'All' }) }
        'transform.sort'      { Sort-PipelineData -Data $Inputs['in'] -SortBy @($config.sortBy) }
        'transform.distinct'  { Select-PipelineDistinct -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.join'      { Join-PipelineData -Left $Inputs['left'] -Right $Inputs['right'] -LeftKey $config.leftKey -RightKey $config.rightKey -JoinType $config.joinType }
        'transform.aggregate' { Group-PipelineData -Data $Inputs['in'] -GroupBy @($config.groupBy) -Aggregations @($config.aggregations) }

        # Output nodes write to disk and pass their data through so they can be chained.
        'output.csv'   { Export-PipelineCsv -Data $Inputs['in'] -Path $config.path -Delimiter $(if ($config.delimiter) { $config.delimiter } else { ',' }); $Inputs['in'] }
        'output.json'  { Export-PipelineJson -Data $Inputs['in'] -Path $config.path; $Inputs['in'] }
        'output.excel' { Export-PipelineExcel -Data $Inputs['in'] -Path $config.path -Worksheet $(if ($config.worksheet) { $config.worksheet } else { 'Sheet1' }); $Inputs['in'] }

        default { throw "Unknown node type '$($Node.type)'." }
    }
}

function Invoke-PipelineDefinition {
    <#
    .SYNOPSIS
        Executes a parsed pipeline definition object and returns the data
        produced by its terminal (sink) nodes.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [switch]$Quiet
    )
    Assert-PipelineHost
    $nodesById = @{}
    foreach ($node in $Definition.nodes) { $nodesById[$node.id] = $node }

    $results = @{}
    $hasOutgoing = @{}
    foreach ($edge in @($Definition.edges)) { $hasOutgoing[$edge.from] = $true }

    foreach ($id in (Get-PipelineExecutionOrder -Definition $Definition)) {
        $node = $nodesById[$id]
        $inputs = @{}
        foreach ($edge in @($Definition.edges)) {
            if ($edge.to -eq $id) {
                $port = if ($edge.toPort) { [string]$edge.toPort } else { 'in' }
                $inputs[$port] = $results[$edge.from]
            }
        }
        if (-not $Quiet) {
            Write-Verbose ("Running node '{0}' ({1})" -f $id, $node.type)
        }
        $results[$id] = @(Invoke-PipelineNode -Node $node -Inputs $inputs)
    }

    # Return the output of every leaf node, keyed by node id.
    $terminal = [ordered]@{}
    foreach ($node in $Definition.nodes) {
        if (-not $hasOutgoing.ContainsKey($node.id)) { $terminal[$node.id] = $results[$node.id] }
    }
    $terminal
}

#endregion PSPipeline core functions
