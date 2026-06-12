# PSPipeline module loader
# Note: no Set-StrictMode here on purpose — the engine reads optional
# properties (e.g. $config.delimiter) straight off ConvertFrom-Json objects,
# which strict mode would turn into terminating errors.

$script:ModuleRoot = $PSScriptRoot

# Core functions are kept in a single standalone file because the code
# generator (ConvertTo-PSPipelineScript) inlines that file verbatim into
# generated scripts. Do not split it or add module-only dependencies to it.
. (Join-Path -Path (Join-Path -Path $script:ModuleRoot -ChildPath 'Core') -ChildPath 'PipelineFunctions.ps1')

foreach ($file in (Get-ChildItem -Path (Join-Path -Path $script:ModuleRoot -ChildPath 'Public') -Filter '*.ps1')) {
    . $file.FullName
}

Export-ModuleMember -Function @(
    'Invoke-PSPipeline'
    'ConvertTo-PSPipelineScript'
    'Get-PipelineEnvironment'
)
