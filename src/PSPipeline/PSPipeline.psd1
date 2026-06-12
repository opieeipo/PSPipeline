@{
    RootModule        = 'PSPipeline.psm1'
    ModuleVersion     = '0.1.0'
    GUID              = '5e1f3a9c-7d24-4b6a-9f0e-8c2b41d7a3e5'
    Author            = 'Matthew Frazier'
    Description       = 'Visual drag-and-drop ETL pipeline designer that compiles to plain PowerShell. Build extract/transform/load flows over delimited text, fixed-width, and JSON data, then run them anywhere PowerShell 5.1+ runs - no third-party ETL platform required.'
    PowerShellVersion = '5.1'
    FunctionsToExport = @(
        'Invoke-PSPipeline'
        'ConvertTo-PSPipelineScript'
        'Get-PipelineEnvironment'
    )
    CmdletsToExport   = @()
    VariablesToExport = @()
    AliasesToExport   = @()
    PrivateData       = @{
        PSData = @{
            Tags       = @('ETL', 'Pipeline', 'CSV', 'TSV', 'JSON', 'FixedWidth', 'Transform', 'Join', 'DataFlow')
            ProjectUri = 'https://github.com/opieeipo/PSPipeline'
            LicenseUri = 'https://github.com/opieeipo/PSPipeline/blob/main/LICENSE'
        }
    }
}
