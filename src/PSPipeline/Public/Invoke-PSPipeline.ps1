function Invoke-PSPipeline {
    <#
    .SYNOPSIS
        Runs a pipeline definition (the JSON saved by the visual designer)
        and returns the data produced by its terminal nodes.
    .DESCRIPTION
        Loads a pipeline definition, topologically sorts its node graph and
        executes each node in dependency order. Output nodes write files as a
        side effect; the function also returns each leaf node's data keyed by
        node id, so pipelines can be used interactively without output nodes.
    .PARAMETER Path
        Path to a pipeline definition .json file (see schemas/pipeline.schema.json).
    .PARAMETER Definition
        An already-parsed pipeline definition object (e.g. from ConvertFrom-Json).
    .EXAMPLE
        Invoke-PSPipeline -Path .\samples\sample-pipeline.json -Verbose
    .EXAMPLE
        $result = Invoke-PSPipeline -Path .\my-pipeline.json
        $result['totals'] | Format-Table
    #>
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path', Position = 0)]
        [string]$Path,

        [Parameter(Mandatory, ParameterSetName = 'Definition', ValueFromPipeline)]
        [object]$Definition
    )
    process {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $Definition = Get-Content -Path $Path -Raw | ConvertFrom-Json
        }
        Invoke-PipelineDefinition -Definition $Definition
    }
}
