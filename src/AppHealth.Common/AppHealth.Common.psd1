@{
    # Module manifest
    ModuleVersion = '1.2.0'
    GUID = 'e6e3757f-17a9-4c91-8ee2-fd57d9f40c6f'
    Author = 'Jamey Walker'
    CompanyName = 'Personal Portfolio'
    Copyright = '(c) 2025. All rights reserved.'
    Description = 'Common functions for application health monitoring and structured logging'
    
    # Requirements
    PowerShellVersion = '7.0'
    RequiredModules = @('PSFramework')
    
    # Exports
    FunctionsToExport = "*"
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    
    # Root Module
    RootModule = 'AppHealth.Common.psm1'
    FileList = @(
        'AppHealth.Common.psd1',
        'AppHealth.Common.psm1'
    )

    # Metadata
    PrivateData = @{
        PSData = @{
            Tags = @('Monitoring','HealthCheck','Logging')
            ProjectUri = 'https://github.com/yourusername/AppHealth-Toolkit'
        }
    }
}
