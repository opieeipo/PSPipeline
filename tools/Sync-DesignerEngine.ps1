<#
    Sync-DesignerEngine.ps1

    Embeds the runnable sources into the offline designer (designer/index.html)
    so the in-browser backends can emit fully self-contained scripts:

      * src/PSPipeline/Core/PipelineFunctions.ps1  -> #ps-engine-source  (PowerShell backend)
      * src/PSPipeline/Core/pipeline-runtime.sh    -> #sh-runtime-source  (shell backend runtime)
      * tools/shellgen.js                          -> #shellgen-source    (shell backend generator)

    Run this whenever any of those sources change. The designer is otherwise
    hand-edited.

    Usage:  pwsh -File tools/Sync-DesignerEngine.ps1   (or run from Windows PowerShell)
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'

$repoRoot     = Split-Path -Path $PSScriptRoot -Parent
$designerPath = Join-Path $repoRoot 'designer/index.html'

# Read as UTF-8 explicitly: Windows PowerShell 5.1's Get-Content defaults to the
# system ANSI code page, which would corrupt any non-ASCII characters on a round trip.
function Read-Utf8([string]$Path) {
    return [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
}

# Replace the content between an HTML start tag and its end marker (exactly once).
function Set-EmbeddedBlock([string]$Html, [string]$StartMarker, [string]$EndMarker, [string]$Content) {
    if ($Content -match '</script>') {
        throw "Embedded content for $StartMarker contains a literal </script> sequence, which cannot live in an HTML script block."
    }
    $startIdx = $Html.IndexOf($StartMarker)
    $endIdx   = if ($startIdx -ge 0) { $Html.IndexOf($EndMarker, $startIdx) } else { -1 }
    if ($startIdx -lt 0 -or $endIdx -lt 0) {
        throw "Could not find markers '$StartMarker' .. '$EndMarker' in $designerPath."
    }
    $before = $Html.Substring(0, $startIdx + $StartMarker.Length)
    $after  = $Html.Substring($endIdx)
    return $before + "`r`n" + $Content.TrimEnd() + "`r`n" + $after
}

$engine   = (Read-Utf8 (Join-Path $repoRoot 'src/PSPipeline/Core/PipelineFunctions.ps1')).TrimEnd()
$runtime  = (Read-Utf8 (Join-Path $repoRoot 'src/PSPipeline/Core/pipeline-runtime.sh')).TrimEnd()
$shellgen  = (Read-Utf8 (Join-Path $repoRoot 'tools/shellgen.js')).TrimEnd()
$samplerun = (Read-Utf8 (Join-Path $repoRoot 'tools/samplerun.js')).TrimEnd()

$html = Read-Utf8 $designerPath
$html = Set-EmbeddedBlock $html '<script type="text/plain" id="ps-engine-source">' '</script><!-- /ps-engine-source -->' $engine
$html = Set-EmbeddedBlock $html '<script type="text/plain" id="sh-runtime-source">' '</script><!-- /sh-runtime-source -->' $runtime
$html = Set-EmbeddedBlock $html '<script id="shellgen-source">' '</script><!-- /shellgen-source -->' $shellgen
$html = Set-EmbeddedBlock $html '<script id="samplerun-source">' '</script><!-- /samplerun-source -->' $samplerun

# Write UTF-8 without a BOM so the HTML file stays clean across re-syncs.
[System.IO.File]::WriteAllText($designerPath, $html, (New-Object System.Text.UTF8Encoding($false)))
Write-Host "Synced engine + shell runtime + shell generator + preview executor into designer/index.html."
