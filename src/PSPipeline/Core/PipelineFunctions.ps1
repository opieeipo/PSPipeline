#region PSPipeline core functions
# ---------------------------------------------------------------------------
# This file is shared between the PSPipeline module AND every generated
# standalone script (ConvertTo-PSPipelineScript inlines it verbatim).
#
# Hard constraints for everything in this file:
#   * Windows PowerShell 5.1 compatible (no PS7-only syntax or parameters)
#   * Built-in cmdlets only -- no required external modules of any kind
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
        PSCustomObject with version, edition, OS, language mode and
        text-encoding behavior information.
    #>
    param([switch]$Refresh)
    if ($script:PipelineEnvironment -and -not $Refresh) { return $script:PipelineEnvironment }

    $psVersion = $PSVersionTable.PSVersion
    $edition   = if ($PSVersionTable.PSEdition) { [string]$PSVersionTable.PSEdition } else { 'Desktop' }

    # $IsWindows does not exist in Windows PowerShell 5.1 (its absence means Windows).
    $isWindowsHost = if ($null -eq (Get-Variable -Name IsWindows -ErrorAction SilentlyContinue)) { $true } else { [bool]$IsWindows }

    $languageMode  = [string]$ExecutionContext.SessionState.LanguageMode
    $isConstrained = $languageMode -ne 'FullLanguage'

    $script:PipelineEnvironment = [pscustomobject]@{
        PSVersion      = $psVersion
        PSEdition      = $edition
        IsWindows      = $isWindowsHost
        LanguageMode   = $languageMode
        IsConstrained  = $isConstrained
        # Windows PowerShell 5.1 writes a UTF-8 BOM with -Encoding UTF8; PowerShell 6+
        # does not unless asked. Used to keep delimited-text output byte-identical
        # (BOM included, so spreadsheets open it correctly) on every host.
        Utf8WritesBom  = $psVersion.Major -le 5
    }
    $script:PipelineEnvironment
}

function Assert-PipelineHost {
    if ($PSVersionTable.PSVersion -lt [version]'5.1') {
        throw "PSPipeline requires Windows PowerShell 5.1 or later (detected $($PSVersionTable.PSVersion))."
    }
    $environment = Get-PipelineEnvironment
    Write-Verbose ("PSPipeline host: PowerShell {0} ({1}), {2}, LanguageMode={3}" -f `
        $environment.PSVersion, $environment.PSEdition,
        $(if ($environment.IsWindows) { 'Windows' } else { 'Non-Windows' }),
        $environment.LanguageMode)
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

function Import-PipelineFixedWidth {
    # Reads a fixed-width / flat text file where each column occupies a fixed
    # range of characters on every line. $Columns is an array of objects with
    # .name, .start (1-based character position) and .length. Values are trimmed.
    # Built-in only (Substring); CLM-safe.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][object[]]$Columns,
        [int]$SkipLines = 0
    )
    $lines = @(Get-Content -Path $Path)
    if ($SkipLines -gt 0) {
        $lines = if ($lines.Count -gt $SkipLines) { @($lines[$SkipLines..($lines.Count - 1)]) } else { @() }
    }
    @(foreach ($line in $lines) {
        if ($null -eq $line -or $line.Length -eq 0) { continue }
        $out = [ordered]@{}
        foreach ($col in $Columns) {
            $start = [int]$col.start - 1
            $length = [int]$col.length
            if ($start -lt 0) { $start = 0 }
            $value = ''
            if ($start -lt $line.Length) {
                $take = $length
                if ($take -gt ($line.Length - $start)) { $take = $line.Length - $start }
                $value = $line.Substring($start, $take)
            }
            $out[[string]$col.name] = $value.Trim()
        }
        [pscustomobject]$out
    })
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

# --- Row operations --------------------------------------------------------

function Limit-PipelineRow {
    # Mode: Top|Bottom|Range. Top/Bottom use Count; Range uses Start (1-based) + Count.
    param([object[]]$Data, [string]$Mode = 'Top', [int]$Count = 10, [int]$Start = 1)
    $rows = @($Data); $n = $rows.Count
    if ($n -eq 0 -or $Count -le 0) { return @() }
    switch ([string]$Mode) {
        'Bottom' { if ($Count -ge $n) { @($rows) } else { @($rows[($n - $Count)..($n - 1)]) } }
        'Range'  {
            $s = $Start - 1; if ($s -lt 0) { $s = 0 }
            if ($s -ge $n) { return @() }
            $e = $s + $Count - 1; if ($e -ge $n) { $e = $n - 1 }
            @($rows[$s..$e])
        }
        default  { if ($Count -ge $n) { @($rows) } else { @($rows[0..($Count - 1)]) } }
    }
}

function Add-PipelineIndex {
    param([object[]]$Data, [string]$Name = 'Index', [int]$Start = 1)
    $i = $Start
    @(foreach ($row in $Data) {
        $out = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) { $out[$p.Name] = $p.Value }
        $out[$Name] = $i; $i++
        [pscustomobject]$out
    })
}

function Edit-PipelineValue {
    # Replace values in $Column. WholeCell: case-insensitive whole-cell match. Otherwise literal substring replace.
    param([object[]]$Data, [Parameter(Mandatory)][string]$Column, [string]$Find = '', [string]$ReplaceWith = '', [switch]$WholeCell)
    @(foreach ($row in $Data) {
        $out = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) {
            if ($p.Name -eq $Column) {
                $val = [string]$p.Value
                if ($WholeCell) { if ($val -eq $Find) { $val = $ReplaceWith } }
                elseif ($Find -ne '') { $val = $val.Replace($Find, $ReplaceWith) }
                $out[$p.Name] = $val
            }
            else { $out[$p.Name] = $p.Value }
        }
        [pscustomobject]$out
    })
}

function Set-PipelineFill {
    # Fill empty cells in $Columns with the last (Down) or next (Up) non-empty value.
    param([object[]]$Data, [string[]]$Columns, [string]$Direction = 'Down')
    $tables = @(foreach ($row in $Data) {
        $o = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) { $o[$p.Name] = $p.Value }
        $o
    })
    if ($tables.Count -eq 0) { return @() }
    foreach ($col in $Columns) {
        $last = $null
        if ($Direction -eq 'Up') {
            for ($i = $tables.Count - 1; $i -ge 0; $i--) {
                if ([string]$tables[$i][$col] -ne '') { $last = $tables[$i][$col] }
                elseif ($null -ne $last) { $tables[$i][$col] = $last }
            }
        }
        else {
            for ($i = 0; $i -lt $tables.Count; $i++) {
                if ([string]$tables[$i][$col] -ne '') { $last = $tables[$i][$col] }
                elseif ($null -ne $last) { $tables[$i][$col] = $last }
            }
        }
    }
    @(foreach ($t in $tables) { [pscustomobject]$t })
}

function Add-PipelineConditional {
    # Adds $Name: the Result of the first matching rule, else $Else. Result/Else are
    # {Column} templates (no code eval, CLM-safe). Rule: { column, operator, value, result }.
    param([object[]]$Data, [Parameter(Mandatory)][string]$Name, [object[]]$Rules, [string]$Else = '')
    @(foreach ($row in $Data) {
        $picked = $Else
        foreach ($rule in $Rules) {
            $cond = [pscustomobject]@{ column = $rule.column; operator = $rule.operator; value = $rule.value }
            if (Test-PipelineCondition -Row $row -Condition $cond) { $picked = [string]$rule.result; break }
        }
        $value = $picked
        foreach ($p in $row.PSObject.Properties) { $value = $value.Replace('{' + $p.Name + '}', [string]$p.Value) }
        $out = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) { $out[$p.Name] = $p.Value }
        $out[$Name] = $value
        [pscustomobject]$out
    })
}

function Edit-PipelineText {
    # Single-column text op. Op: trim|lower|upper|title|before|after|between.
    # before/after/between extract relative to Find (and Find2 for between).
    # If As is set, the result goes to a new column; otherwise it replaces Column.
    param([object[]]$Data, [Parameter(Mandatory)][string]$Column, [string]$Op = 'trim',
          [string]$Find = '', [string]$Find2 = '', [string]$As = '')
    @(foreach ($row in $Data) {
        $src = [string]$row.$Column
        $val = switch ([string]$Op) {
            'lower' { $src.ToLower() }
            'upper' { $src.ToUpper() }
            'title' {
                $parts = $src.ToLower() -split ' '
                ($parts | ForEach-Object { if ($_.Length -gt 0) { $_.Substring(0, 1).ToUpper() + $_.Substring(1) } else { $_ } }) -join ' '
            }
            'before' { $i = $src.IndexOf($Find); if ($Find -ne '' -and $i -ge 0) { $src.Substring(0, $i) } else { '' } }
            'after'  { $i = $src.IndexOf($Find); if ($Find -ne '' -and $i -ge 0) { $src.Substring($i + $Find.Length) } else { '' } }
            'between' {
                $i = $src.IndexOf($Find)
                if ($Find -ne '' -and $i -ge 0) {
                    $start = $i + $Find.Length
                    $j = if ($Find2 -ne '') { $src.IndexOf($Find2, $start) } else { -1 }
                    if ($j -ge 0) { $src.Substring($start, $j - $start) } else { $src.Substring($start) }
                } else { '' }
            }
            default { $src.Trim() }
        }
        $out = [ordered]@{}
        foreach ($p in $row.PSObject.Properties) {
            if (-not $As -and $p.Name -eq $Column) { $out[$p.Name] = $val } else { $out[$p.Name] = $p.Value }
        }
        if ($As) { $out[$As] = $val }
        [pscustomobject]$out
    })
}

function Union-PipelineData {
    # Stacks the rows of every input table. Output columns are the union of all
    # input columns in first-appearance order; cells absent from a row are empty.
    param([object[]]$Tables)
    $cols = New-Object System.Collections.ArrayList
    $seen = @{}
    foreach ($t in $Tables) {
        $rows = @($t)
        if ($rows.Count -gt 0) {
            foreach ($p in $rows[0].PSObject.Properties) {
                if (-not $seen.ContainsKey($p.Name)) { $seen[$p.Name] = $true; [void]$cols.Add($p.Name) }
            }
        }
    }
    @(foreach ($t in $Tables) {
        foreach ($row in @($t)) {
            $out = [ordered]@{}
            foreach ($c in $cols) {
                $prop = $row.PSObject.Properties[$c]
                $out[$c] = if ($prop) { $prop.Value } else { '' }
            }
            [pscustomobject]$out
        }
    })
}

function Convert-PipelineUnpivot {
    # Wide -> long. Keeps $Keep columns; melts every other column into two columns:
    # $AttributeName (the source column name) and $ValueName (its cell value).
    param([object[]]$Data, [string[]]$Keep, [string]$AttributeName = 'Attribute', [string]$ValueName = 'Value')
    $rows = @($Data); if ($rows.Count -eq 0) { return @() }
    $valCols = @(foreach ($p in $rows[0].PSObject.Properties.Name) { if ($Keep -notcontains $p) { $p } })
    @(foreach ($row in $rows) {
        foreach ($vc in $valCols) {
            $out = [ordered]@{}
            foreach ($k in $Keep) { $out[$k] = $row.$k }
            $out[$AttributeName] = $vc
            $out[$ValueName] = $row.$vc
            [pscustomobject]$out
        }
    })
}

function Convert-PipelinePivot {
    # Long -> wide. Groups by $GroupBy; the distinct values of $PivotColumn become
    # columns whose cells are the $Aggregate (First|Sum|Count) of $ValueColumn.
    param([object[]]$Data, [string[]]$GroupBy, [Parameter(Mandatory)][string]$PivotColumn, [string]$ValueColumn, [string]$Aggregate = 'First')
    $rows = @($Data)
    $pivotVals = New-Object System.Collections.ArrayList
    $pseen = @{}
    foreach ($row in $rows) { $pv = [string]$row.$PivotColumn; if (-not $pseen.ContainsKey($pv)) { $pseen[$pv] = $true; [void]$pivotVals.Add($pv) } }
    $order = New-Object System.Collections.ArrayList
    $groups = @{}
    foreach ($row in $rows) {
        $key = (@(foreach ($g in $GroupBy) { [string]$row.$g }) -join [char]31)
        if (-not $groups.ContainsKey($key)) {
            $groups[$key] = [pscustomobject]@{ KeyVals = @(foreach ($g in $GroupBy) { $row.$g }); Rows = (New-Object System.Collections.ArrayList) }
            [void]$order.Add($key)
        }
        [void]$groups[$key].Rows.Add($row)
    }
    @(foreach ($key in $order) {
        $grp = $groups[$key]
        $out = [ordered]@{}
        for ($gi = 0; $gi -lt $GroupBy.Count; $gi++) { $out[$GroupBy[$gi]] = $grp.KeyVals[$gi] }
        foreach ($pv in $pivotVals) {
            $matching = @($grp.Rows | Where-Object { [string]$_.$PivotColumn -eq $pv })
            $out[$pv] = switch ([string]$Aggregate) {
                'Count' { $matching.Count }
                'Sum' {
                    $nums = @(foreach ($m in $matching) { $n = 0.0; if ([double]::TryParse([string]$m.$ValueColumn, [ref]$n)) { $n } })
                    ($nums | Measure-Object -Sum).Sum
                }
                default { if ($matching.Count -gt 0) { $matching[0].$ValueColumn } else { '' } }
            }
        }
        [pscustomobject]$out
    })
}

# --- Date / type ------------------------------------------------------------

function Get-PipelineDateParts {
    # Parse an ISO-ish date (yyyy<sep>MM<sep>dd, any non-digit separators, optional
    # trailing time) into integer Y/M/D. Returns $null if it does not match.
    param([string]$Value)
    if ($Value -match '^\s*(\d{4})\D+(\d{1,2})\D+(\d{1,2})') {
        [pscustomobject]@{ Y = [int]$matches[1]; M = [int]$matches[2]; D = [int]$matches[3] }
    } else { $null }
}

function Get-PipelineJdn {
    # Julian Day Number from a proleptic Gregorian date. Pure integer math so it is
    # identical across PowerShell, awk, JavaScript, and M.
    param([int]$Y, [int]$M, [int]$D)
    $a = [int][math]::Floor((14 - $M) / 12)
    $y2 = $Y + 4800 - $a
    $m2 = $M + 12 * $a - 3
    [int]($D + [int][math]::Floor((153 * $m2 + 2) / 5) + 365 * $y2 + [int][math]::Floor($y2 / 4) - [int][math]::Floor($y2 / 100) + [int][math]::Floor($y2 / 400) - 32045)
}

function Format-PipelineDate {
    param([int]$Y, [int]$M, [int]$D, [string]$Format)
    $yyyy = '{0:D4}' -f $Y; $MM = '{0:D2}' -f $M; $dd = '{0:D2}' -f $D
    switch ($Format) {
        'yyyy/MM/dd' { "$yyyy/$MM/$dd" }
        'MM/dd/yyyy' { "$MM/$dd/$yyyy" }
        'dd/MM/yyyy' { "$dd/$MM/$yyyy" }
        'yyyyMMdd'   { "$yyyy$MM$dd" }
        'yyyy-MM'    { "$yyyy-$MM" }
        default      { "$yyyy-$MM-$dd" }
    }
}

function Convert-PipelineDate {
    # Extract a component, reformat, or take a day-difference from an ISO-ish date column.
    param([object[]]$Data, [string]$Column, [string]$Op, [string]$Column2, [string]$Format, [string]$As)
    $target = if ($As) { $As } else { $Column }
    @(foreach ($row in $Data) {
        $p = Get-PipelineDateParts ([string]$row.$Column)
        $result = if ($null -eq $p) { '' } else {
            switch ($Op) {
                'year'    { $p.Y }
                'month'   { $p.M }
                'day'     { $p.D }
                'weekday' { ((Get-PipelineJdn $p.Y $p.M $p.D) % 7) + 1 }  # ISO: Monday=1 .. Sunday=7
                'format'  { Format-PipelineDate $p.Y $p.M $p.D $Format }
                'diffdays' {
                    $p2 = Get-PipelineDateParts ([string]$row.$Column2)
                    if ($null -eq $p2) { '' } else { (Get-PipelineJdn $p.Y $p.M $p.D) - (Get-PipelineJdn $p2.Y $p2.M $p2.D) }
                }
                default { '' }
            }
        }
        $out = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
        $out[$target] = $result
        [pscustomobject]$out
    })
}

function Convert-PipelineCast {
    # Light type normalization (mostly meaningful for the M export's typing).
    param([object[]]$Data, [string]$Column, [string]$To)
    @(foreach ($row in $Data) {
        $v = [string]$row.$Column
        $n = 0.0
        $new = switch ($To) {
            'number'  { if ([double]::TryParse($v, [ref]$n)) { $n } else { $v } }
            'integer' { if ([double]::TryParse($v, [ref]$n)) { [int][math]::Truncate($n) } else { $v } }
            default   { $v }
        }
        $out = [ordered]@{}
        foreach ($prop in $row.PSObject.Properties) { $out[$prop.Name] = $prop.Value }
        $out[$Column] = $new
        [pscustomobject]$out
    })
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
    # Functions: Count, Sum, Average, Min, Max, First, Median, CountDistinct, StringJoin
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
                'CountDistinct' {
                    $seen = @{}
                    foreach ($row in $group.Group) { $seen[[string]$row.($agg.column)] = $true }
                    $seen.Count
                }
                'StringJoin' { (@(foreach ($row in $group.Group) { [string]$row.($agg.column) })) -join ', ' }
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
                        'Median'  {
                            $sorted = @($numbers | Sort-Object)
                            $c = $sorted.Count
                            if ($c -eq 0) { '' }
                            elseif ($c % 2 -eq 1) { $sorted[[int](($c - 1) / 2)] }
                            else { ($sorted[$c / 2 - 1] + $sorted[$c / 2]) / 2 }
                        }
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
    # (which spreadsheets expect); PowerShell 6+ needs to be asked for one.
    $encoding = if ((Get-PipelineEnvironment).Utf8WritesBom) { 'UTF8' } else { 'utf8BOM' }
    $Data | Export-Csv -Path $Path -NoTypeInformation -Delimiter $Delimiter -Encoding $encoding
}

function Export-PipelineJson {
    param([object[]]$Data, [Parameter(Mandatory)][string]$Path)
    Assert-PipelineOutputDirectory -Path $Path
    ConvertTo-Json -InputObject $Data -Depth 10 | Set-Content -Path $Path -Encoding UTF8
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
    # $InputList is the ordered list of ALL incoming results (used by multi-input
    # nodes like union, which accept several edges into one port).
    param(
        [Parameter(Mandatory)]$Node,
        [hashtable]$Inputs,
        [object[]]$InputList = @()
    )
    $config = $Node.config
    switch ([string]$Node.type) {
        'input.csv'        { Import-PipelineCsv -Path $config.path -Delimiter $(if ($config.delimiter) { $config.delimiter } else { ',' }) }
        'input.fixedwidth' { Import-PipelineFixedWidth -Path $config.path -Columns @($config.columns) -SkipLines $(if ($config.skipLines) { [int]$config.skipLines } else { 0 }) }
        'input.json'       { Import-PipelineJson -Path $config.path }

        'transform.select'    { Select-PipelineColumn -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.drop'      { Remove-PipelineColumn -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.rename'    { Rename-PipelineColumn -Data $Inputs['in'] -Renames @($config.renames) }
        'transform.derive'    { Add-PipelineColumn -Data $Inputs['in'] -Name $config.name -Template $config.template }
        'transform.filter'    { Where-PipelineRow -Data $Inputs['in'] -Conditions @($config.conditions) -Match $(if ($config.match) { $config.match } else { 'All' }) }
        'transform.sort'      { Sort-PipelineData -Data $Inputs['in'] -SortBy @($config.sortBy) }
        'transform.distinct'  { Select-PipelineDistinct -Data $Inputs['in'] -Columns @($config.columns) }
        'transform.limit'       { Limit-PipelineRow -Data $Inputs['in'] -Mode $(if ($config.mode) { $config.mode } else { 'Top' }) -Count $(if ($null -ne $config.count) { [int]$config.count } else { 10 }) -Start $(if ($config.start) { [int]$config.start } else { 1 }) }
        'transform.index'       { Add-PipelineIndex -Data $Inputs['in'] -Name $(if ($config.name) { $config.name } else { 'Index' }) -Start $(if ($null -ne $config.start) { [int]$config.start } else { 1 }) }
        'transform.replace'     { Edit-PipelineValue -Data $Inputs['in'] -Column $config.column -Find $(if ($null -ne $config.find) { [string]$config.find } else { '' }) -ReplaceWith $(if ($null -ne $config.replaceWith) { [string]$config.replaceWith } else { '' }) -WholeCell:$([bool]$config.wholeCell) }
        'transform.fill'        { Set-PipelineFill -Data $Inputs['in'] -Columns @($config.columns) -Direction $(if ($config.direction) { $config.direction } else { 'Down' }) }
        'transform.conditional' { Add-PipelineConditional -Data $Inputs['in'] -Name $config.name -Rules @($config.rules) -Else $(if ($null -ne $config.'else') { [string]$config.'else' } else { '' }) }
        'transform.text'        { Edit-PipelineText -Data $Inputs['in'] -Column $config.column -Op $(if ($config.op) { $config.op } else { 'trim' }) -Find $(if ($null -ne $config.find) { [string]$config.find } else { '' }) -Find2 $(if ($null -ne $config.find2) { [string]$config.find2 } else { '' }) -As $(if ($config.as) { [string]$config.as } else { '' }) }
        'transform.union'       { Union-PipelineData -Tables $InputList }
        'transform.date'        { Convert-PipelineDate -Data $Inputs['in'] -Column $config.column -Op $config.op -Column2 $config.column2 -Format $config.format -As $config.as }
        'transform.cast'        { Convert-PipelineCast -Data $Inputs['in'] -Column $config.column -To $(if ($config.to) { $config.to } else { 'text' }) }
        'transform.unpivot'     { Convert-PipelineUnpivot -Data $Inputs['in'] -Keep @($config.keep) -AttributeName $(if ($config.attributeName) { $config.attributeName } else { 'Attribute' }) -ValueName $(if ($config.valueName) { $config.valueName } else { 'Value' }) }
        'transform.pivot'       { Convert-PipelinePivot -Data $Inputs['in'] -GroupBy @($config.groupBy) -PivotColumn $config.pivotColumn -ValueColumn $config.valueColumn -Aggregate $(if ($config.aggregate) { $config.aggregate } else { 'First' }) }
        'transform.join'      { Join-PipelineData -Left $Inputs['left'] -Right $Inputs['right'] -LeftKey $config.leftKey -RightKey $config.rightKey -JoinType $config.joinType }
        'transform.aggregate' { Group-PipelineData -Data $Inputs['in'] -GroupBy @($config.groupBy) -Aggregations @($config.aggregations) }

        # Output nodes write to disk and pass their data through so they can be chained.
        'output.csv'   { Export-PipelineCsv -Data $Inputs['in'] -Path $config.path -Delimiter $(if ($config.delimiter) { $config.delimiter } else { ',' }); $Inputs['in'] }
        'output.json'  { Export-PipelineJson -Data $Inputs['in'] -Path $config.path; $Inputs['in'] }

        default { throw "Unknown node type '$($Node.type)'." }
    }
}

function Expand-PipelineValue {
    # Recursively replaces ${Name} tokens in every string value of $Value using
    # the $Params map (name -> value). Used to bind runtime parameters into a
    # parsed pipeline definition (paths and any other string config).
    param($Value, [hashtable]$Params)
    if ($null -eq $Value) { return $Value }
    if ($Value -is [string]) {
        $out = $Value
        foreach ($k in $Params.Keys) { $out = $out.Replace('${' + $k + '}', [string]$Params[$k]) }
        return $out
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $o = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $o[$p.Name] = Expand-PipelineValue -Value $p.Value -Params $Params }
        return [pscustomobject]$o
    }
    if ($Value -is [object[]]) {
        return @(foreach ($item in $Value) { Expand-PipelineValue -Value $item -Params $Params })
    }
    return $Value
}

function Resolve-PipelineParameter {
    # Effective parameter map = each declared parameter's default, overridden by $Overrides.
    param($Definition, [hashtable]$Overrides = @{})
    $vals = @{}
    foreach ($p in @($Definition.parameters)) {
        if ($null -eq $p -or -not $p.name) { continue }
        $name = [string]$p.name
        $vals[$name] = if ($Overrides.ContainsKey($name)) { [string]$Overrides[$name] } else { [string]$p.default }
    }
    $vals
}

function Invoke-PipelineDefinition {
    <#
    .SYNOPSIS
        Executes a parsed pipeline definition object and returns the data
        produced by its terminal (sink) nodes.
    #>
    param(
        [Parameter(Mandatory)]$Definition,
        [switch]$Quiet,
        [hashtable]$Parameters = @{}
    )
    Assert-PipelineHost
    if ($Definition.parameters) {
        $Definition = Expand-PipelineValue -Value $Definition -Params (Resolve-PipelineParameter -Definition $Definition -Overrides $Parameters)
    }
    $nodesById = @{}
    foreach ($node in $Definition.nodes) { $nodesById[$node.id] = $node }

    $results = @{}
    $hasOutgoing = @{}
    foreach ($edge in @($Definition.edges)) { $hasOutgoing[$edge.from] = $true }

    foreach ($id in (Get-PipelineExecutionOrder -Definition $Definition)) {
        $node = $nodesById[$id]
        $inputs = @{}
        $inputList = New-Object System.Collections.ArrayList
        foreach ($edge in @($Definition.edges)) {
            if ($edge.to -eq $id) {
                $port = if ($edge.toPort) { [string]$edge.toPort } else { 'in' }
                $inputs[$port] = $results[$edge.from]
                [void]$inputList.Add($results[$edge.from])
            }
        }
        if (-not $Quiet) {
            Write-Verbose ("Running node '{0}' ({1})" -f $id, $node.type)
        }
        $results[$id] = @(Invoke-PipelineNode -Node $node -Inputs $inputs -InputList $inputList)
    }

    # Return the output of every leaf node, keyed by node id.
    $terminal = [ordered]@{}
    foreach ($node in $Definition.nodes) {
        if (-not $hasOutgoing.ContainsKey($node.id)) { $terminal[$node.id] = $results[$node.id] }
    }
    $terminal
}

#endregion PSPipeline core functions
