function Resolve-AppHealthPath {
<#
.SYNOPSIS
    Resolves a standardized path within the application repository, such as for logs or configs.
.DESCRIPTION
    This function determines the root of the repository by searching upwards from a given starting point
    for a marker file (like .gitignore). It then constructs a full, absolute path to a specified subdirectory
    (e.g., 'logs', 'config').

    This provides a reliable way for scripts, regardless of their location within the repository, to find
    common, top-level directories. If the repository root cannot be determined, it falls back to a path
    relative to the script's own location as a safety measure.
.PARAMETER PathType
    The type of path to resolve. This determines the top-level subdirectory to look for.
    Valid values are 'Logs', 'Config'.
.PARAMETER AppName
    The name of the application or component, used to create a subfolder within the main directory
    (e.g., 'arcgis', 'activedirectory'). This helps organize outputs from different scripts.
.PARAMETER Environment
    An optional environment name (e.g., 'dev', 'prod') to create a final subfolder, further
    organizing the path.
.PARAMETER StartPath
    The starting path for the search. This should typically be the script's own location, `$PSScriptRoot`.
.PARAMETER RootMarker
    The name of the file or folder that marks the root of the repository. Defaults to '.gitignore'.
.EXAMPLE
    PS C:\> $logPath = Resolve-AppHealthPath -PathType Logs -AppName 'arcgis' -Environment 'dev' -StartPath $PSScriptRoot
    # Assuming the script is in C:\repos\my-project\scripts\apps\arcgis,
    # and C:\repos\my-project\.gitignore exists,
    # $logPath will be 'C:\repos\my-project\logs\arcgis\dev'
.RETURNS
    [string] An absolute path to the resolved directory.
#>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Logs', 'Config')]
        [string]$PathType,

        [Parameter(Mandatory = $true)]
        [string]$AppName,

        [string]$Environment,

        [Parameter(Mandatory = $true)]
        [string]$StartPath,

        [string]$RootMarker = '.gitignore'
    )

    # Find the repository root by walking up the directory tree from the start path
    $repoRoot = $StartPath
    while ($repoRoot -and -not (Test-Path (Join-Path $repoRoot $RootMarker))) {
        $repoRoot = Split-Path -Parent $repoRoot
    }

    # Start with a base path. If we found the repo root, use it. Otherwise, use the script's path.
    $basePath = ''
    if (-not $repoRoot) {
        Write-Warning "Could not determine repository root by searching for '$RootMarker'. Defaulting to a path relative to the start path."
        $basePath = $StartPath
    }
    else {
        $basePath = $repoRoot
    }
    
    # Define the child segments to append to the base path
    $childSegments = @(
        $PathType.ToLower(),
        $AppName
    )
    if (-not [string]::IsNullOrWhiteSpace($Environment)) {
        $childSegments += $Environment.ToLower()
    }

    # Iteratively join the base path with each child segment. This is the most reliable method.
    $finalPath = $basePath
    foreach ($segment in $childSegments) {
        $finalPath = Join-Path -Path $finalPath -ChildPath $segment
    }
    
    # Return the fully resolved, absolute path string
    return $finalPath
}