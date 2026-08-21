# Root module file
$ErrorActionPreference = 'Stop'

# Module state vars
$script:LogFileDirectory = $null
$script:LogFileName = $null
$script:FullLogPath = $null
$script:Timestamp = $null
$script:UseEventLog = $null


# Get public and private function definition files
$PublicFunctions = @(Get-ChildItem -Path $PSScriptRoot\Public\*.ps1 -ErrorAction SilentlyContinue)
$PrivateFunctions = @(Get-ChildItem -Path $PSScriptRoot\Private\*.ps1 -ErrorAction SilentlyContinue)

# Dot source the functions
foreach ($import in @($PublicFunctions + $PrivateFunctions)) {
    try {
        Write-Verbose "Importing $($import.FullName)"
        . $import.FullName
    }
    catch {
        Write-Error "Failed to import function $($import.FullName): $_"
    }
}

# Export public functions
Export-ModuleMember -Function $PublicFunctions.BaseName

