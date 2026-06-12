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
    It 'classifies Excel support as one of the known modes' {
        (Get-PipelineEnvironment).ExcelSupport | Should -BeIn @('ImportExcel', 'Com', 'None')
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
