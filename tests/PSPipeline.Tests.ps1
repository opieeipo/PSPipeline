# Pester 5 tests for the PSPipeline core engine.
# Run from the repository root:  Invoke-Pester -Path .\tests

BeforeAll {
    $repoRoot = Split-Path -Path $PSScriptRoot -Parent
    Import-Module (Join-Path $repoRoot 'src/PSPipeline/PSPipeline.psd1') -Force

    # Inline test data
    $script:People = @(
        [pscustomobject]@{ Id = '1'; Name = 'Ada';   Dept = 'Eng';   Salary = '100' }
        [pscustomobject]@{ Id = '2'; Name = 'Brian'; Dept = 'Eng';   Salary = '90'  }
        [pscustomobject]@{ Id = '3'; Name = 'Cleo';  Dept = 'Sales'; Salary = '80'  }
    )
    $script:Badges = @(
        [pscustomobject]@{ PersonId = '1'; Badge = 'Blue' }
        [pscustomobject]@{ PersonId = '3'; Badge = 'Red'  }
        [pscustomobject]@{ PersonId = '9'; Badge = 'Gray' }
    )

    # The core functions are module-private; pull them into a usable scope.
    $script:Module = Get-Module PSPipeline
}

Describe 'Get-PipelineEnvironment' {
    It 'reports the running PowerShell version' {
        (Get-PipelineEnvironment).PSVersion | Should -Be $PSVersionTable.PSVersion
    }
    It 'reports a UTF-8 BOM policy as a boolean' {
        (Get-PipelineEnvironment).Utf8WritesBom | Should -BeOfType [bool]
    }
    It 'no longer exposes any Excel capability fields' {
        (Get-PipelineEnvironment).PSObject.Properties.Name | Should -Not -Contain 'ExcelSupport'
    }
}

Describe 'Import-PipelineFixedWidth' {
    It 'slices fixed-width lines into trimmed columns' {
        $file = Join-Path $TestDrive 'fixed.txt'
        $line1 = ('1'.PadRight(5)) + ('Ada'.PadRight(20)) + ('Eng'.PadRight(5))
        $line2 = ('2'.PadRight(5)) + ('Brian'.PadRight(20)) + ('Sales'.PadRight(5))
        Set-Content -Path $file -Value @($line1, $line2)
        $cols = @(
            [pscustomobject]@{ name = 'Id';   start = 1;  length = 5 }
            [pscustomobject]@{ name = 'Name'; start = 6;  length = 20 }
            [pscustomobject]@{ name = 'Dept'; start = 26; length = 5 }
        )
        $result = & $Module { param($p, $c) Import-PipelineFixedWidth -Path $p -Columns $c } $file $cols
        $result.Count       | Should -Be 2
        $result[0].Id       | Should -Be '1'
        $result[0].Name     | Should -Be 'Ada'
        $result[1].Dept     | Should -Be 'Sales'
    }
    It 'honours SkipLines for header rows' {
        $file = Join-Path $TestDrive 'fixed-hdr.txt'
        Set-Content -Path $file -Value @('HEADER', ('7'.PadRight(5)))
        $cols = @([pscustomobject]@{ name = 'Id'; start = 1; length = 5 })
        $result = & $Module { param($p, $c) Import-PipelineFixedWidth -Path $p -Columns $c -SkipLines 1 } $file $cols
        $result.Count | Should -Be 1
        $result[0].Id | Should -Be '7'
    }
}

Describe 'Join-PipelineData' {
    It 'inner join keeps only matching rows' {
        $result = & $Module { param($l, $r) Join-PipelineData -Left $l -Right $r -LeftKey Id -RightKey PersonId -JoinType Inner } $People $Badges
        $result.Count | Should -Be 2
        ($result | Where-Object Name -eq 'Ada').Badge | Should -Be 'Blue'
    }
    It 'left join keeps unmatched left rows with null right columns' {
        $result = & $Module { param($l, $r) Join-PipelineData -Left $l -Right $r -LeftKey Id -RightKey PersonId -JoinType Left } $People $Badges
        $result.Count | Should -Be 3
        ($result | Where-Object Name -eq 'Brian').Badge | Should -BeNullOrEmpty
    }
    It 'full join includes unmatched rows from both sides' {
        $result = & $Module { param($l, $r) Join-PipelineData -Left $l -Right $r -LeftKey Id -RightKey PersonId -JoinType Full } $People $Badges
        $result.Count | Should -Be 4
    }
}

Describe 'Where-PipelineRow' {
    It 'compares numerically when both sides are numbers' {
        $conditions = @([pscustomobject]@{ column = 'Salary'; operator = 'ge'; value = '90' })
        $result = & $Module { param($d, $c) Where-PipelineRow -Data $d -Conditions $c } $People $conditions
        $result.Count | Should -Be 2
    }
}

Describe 'Group-PipelineData' {
    It 'sums and counts per group' {
        $aggs = @(
            [pscustomobject]@{ column = 'Salary'; function = 'Sum';   as = 'Total' }
            [pscustomobject]@{ column = 'Id';     function = 'Count'; as = 'Heads' }
        )
        $result = & $Module { param($d, $g, $a) Group-PipelineData -Data $d -GroupBy $g -Aggregations $a } $People @('Dept') $aggs
        ($result | Where-Object Dept -eq 'Eng').Total | Should -Be 190
        ($result | Where-Object Dept -eq 'Eng').Heads | Should -Be 2
    }
}

Describe 'Row operations' {
    It 'limit Top keeps the first N rows' {
        $r = & $Module { param($d) Limit-PipelineRow -Data $d -Mode Top -Count 2 } $People
        $r.Count | Should -Be 2
        $r[0].Name | Should -Be 'Ada'
    }
    It 'limit Bottom keeps the last N rows' {
        $r = & $Module { param($d) Limit-PipelineRow -Data $d -Mode Bottom -Count 1 } $People
        $r.Count | Should -Be 1
        $r[0].Name | Should -Be 'Cleo'
    }
    It 'index adds a 1-based row number' {
        $r = & $Module { param($d) Add-PipelineIndex -Data $d -Name Row } $People
        ($r.Row -join ',') | Should -Be '1,2,3'
    }
    It 'replace whole-cell is case-insensitive' {
        $r = & $Module { param($d) Edit-PipelineValue -Data $d -Column Dept -Find 'eng' -ReplaceWith 'E' -WholeCell } $People
        ($r.Dept -join '|') | Should -Be 'E|E|Sales'
    }
    It 'fill down carries the last non-empty value' {
        $data = @(
            [pscustomobject]@{ K = 'a'; V = 'x' }
            [pscustomobject]@{ K = 'b'; V = '' }
            [pscustomobject]@{ K = 'c'; V = 'y' }
            [pscustomobject]@{ K = 'd'; V = '' }
        )
        $r = & $Module { param($d) Set-PipelineFill -Data $d -Columns V -Direction Down } $data
        ($r.V -join ',') | Should -Be 'x,x,y,y'
    }
}

Describe 'Conditional column' {
    It 'picks the first matching rule, else the default' {
        $rules = @([pscustomobject]@{ column = 'Salary'; operator = 'ge'; value = '90'; result = 'High' })
        $r = & $Module { param($d, $ru) Add-PipelineConditional -Data $d -Name Band -Rules $ru -Else 'Low' } $People $rules
        ($r.Band -join ',') | Should -Be 'High,High,Low'
    }
}

Describe 'Text operations' {
    BeforeAll {
        $script:Row = @([pscustomobject]@{ Name = '  ada LOVELACE  '; Email = 'ada@math.org' })
    }
    It 'trims surrounding whitespace' {
        (& $Module { param($d) Edit-PipelineText -Data $d -Column Name -Op trim } $Row)[0].Name | Should -Be 'ada LOVELACE'
    }
    It 'title-cases' {
        $trimmed = & $Module { param($d) Edit-PipelineText -Data $d -Column Name -Op trim } $Row
        (& $Module { param($d) Edit-PipelineText -Data $d -Column Name -Op title } $trimmed)[0].Name | Should -Be 'Ada Lovelace'
    }
    It 'extracts before / after into a new column' {
        (& $Module { param($d) Edit-PipelineText -Data $d -Column Email -Op before -Find '@' -As User } $Row)[0].User | Should -Be 'ada'
        (& $Module { param($d) Edit-PipelineText -Data $d -Column Email -Op after -Find '@' -As Domain } $Row)[0].Domain | Should -Be 'math.org'
    }
    It 'extracts between two markers' {
        (& $Module { param($d) Edit-PipelineText -Data $d -Column Email -Op between -Find 'a' -Find2 '@' -As Mid } $Row)[0].Mid | Should -Be 'da'
    }
}

Describe 'Pipeline parameters' {
    It 'resolves declared defaults, overridden by -Parameters' {
        $def = [pscustomobject]@{ parameters = @([pscustomobject]@{ name = 'Tag'; default = 'D' }) }
        (& $Module { param($d) Resolve-PipelineParameter -Definition $d } $def)['Tag'] | Should -Be 'D'
        (& $Module { param($d) Resolve-PipelineParameter -Definition $d -Overrides @{ Tag = 'O' } } $def)['Tag'] | Should -Be 'O'
    }
    It 'expands ${tokens} in nested string config' {
        $obj = [pscustomobject]@{ config = [pscustomobject]@{ path = 'in-${Tag}.csv' } }
        $r = & $Module { param($o) Expand-PipelineValue -Value $o -Params @{ Tag = 'X' } } $obj
        $r.config.path | Should -Be 'in-X.csv'
    }
    It 'binds a parameter into an input path at run time, with override' {
        $a = Join-Path $TestDrive 'a.csv'; Set-Content -Path $a -Value @('Id', '1', '2')
        $b = Join-Path $TestDrive 'b.csv'; Set-Content -Path $b -Value @('Id', '9', '8', '7')
        $def = [pscustomobject]@{
            name = 'p'; version = 1
            parameters = @([pscustomobject]@{ name = 'InFile'; default = $a })
            nodes = @([pscustomobject]@{ id = 'in'; type = 'input.csv'; config = [pscustomobject]@{ path = '${InFile}' } })
            edges = @()
        }
        (Invoke-PSPipeline -Definition $def)['in'].Count | Should -Be 2
        (Invoke-PSPipeline -Definition $def -Parameters @{ InFile = $b })['in'].Count | Should -Be 3
    }
}

Describe 'Sample pipeline end-to-end' {
    It 'runs sample-pipeline.json and writes the report' {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        Push-Location $repoRoot
        try {
            $result = Invoke-PSPipeline -Path (Join-Path $repoRoot 'samples/sample-pipeline.json')
            $result['report'] | Should -Not -BeNullOrEmpty
            Test-Path (Join-Path $repoRoot 'samples/output/customer-order-summary.csv') | Should -BeTrue
        }
        finally { Pop-Location }
    }
}

Describe 'ConvertTo-PSPipelineScript' {
    It 'generates a parseable standalone script' {
        $repoRoot = Split-Path -Path $PSScriptRoot -Parent
        $scriptText = ConvertTo-PSPipelineScript -Path (Join-Path $repoRoot 'samples/sample-pipeline.json')
        $tokens = $null; $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($scriptText, [ref]$tokens, [ref]$errors)
        $errors.Count | Should -Be 0
    }
}
