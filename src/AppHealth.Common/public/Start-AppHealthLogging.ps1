<#
.SYNOPSIS
Configures PSFramework logging for the app health checks, creating a JSON log file and optionally enabling Windows Event Log output.

.DESCRIPTION
Start-AppHealthLogging prepares PSFramework’s logging providers for this module:
- Ensures the specified log directory exists.
- Sets the JSON log file path to: <LogFileDirectory>\<LogFileName>_<Timestamp>.log.json
- Tunes JSON file provider options for cleaner output.
- Optionally reduces informational chatter when emitting logs intended for SolarWinds ingestion.
- Optionally enables the Windows Event Log provider (best effort; continues with file logging if enabling fails).

This command returns no output; it configures global PSFramework settings and enables providers. After calling it, use your module’s logging command (for example, Write-AppLog) or Write-PSFMessage to emit log entries.

Note on Timestamp: The value becomes part of the file name. Use a file-system-safe format such as (Get-Date -Format 'yyyyMMdd-HHmmss') to avoid invalid characters like ":" on Windows.

.PARAMETER LogFileDirectory
Directory in which to create the log file. The directory is created if it doesn’t exist. Relative paths are resolved prior to use.

.PARAMETER LogFileName
Base name for the log file (without extension). The final file name becomes:
<LogFileName>_<Timestamp>.log.json

.PARAMETER EmitForSolarWinds
Switch to reduce informational noise for SolarWinds collection. Sets PSFramework.Message.Info.Maximum to 1 (otherwise 3).

.PARAMETER UseEventLog
Enable the PSFramework eventlog provider in addition to the JSON log file. This may require administrative privileges to register the event source. If enabling fails, the function logs an error and continues with the JSON file provider only.

.PARAMETER Timestamp
String used in the log file name to distinguish runs. Recommended: (Get-Date -Format 'yyyyMMdd-HHmmss').

.INPUTS
None. Does not accept pipeline input.

.OUTPUTS
None. This command configures PSFramework logging and enables providers.

.EXAMPLES
Example 1: Configure JSON logging to a directory
PS> $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
PS> Start-AppHealthLogging -LogFileDirectory 'C:\Logs\AppHealth' -LogFileName 'app-health' -Timestamp $ts
PS> # Now emit logs using your logging function or PSFramework:
PS> Write-PSFMessage -Level Info -Message 'Health check initialized.'

Example 2: Configure for SolarWinds ingestion with Event Log enabled
PS> $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
PS> Start-AppHealthLogging -LogFileDirectory 'D:\Ops\Logs' -LogFileName 'health' -Timestamp $ts -EmitForSolarWinds -UseEventLog
PS> Write-PSFMessage -Level Warning -Message 'Endpoint latency above threshold.'

Example 3: Retrieve the configured log file path
PS> Get-PSFConfigValue -FullName 'PSFramework.Logging.LogFile.FilePath'

.NOTES
- Requires the PSFramework module. Install-Module PSFramework -Scope AllUsers (or CurrentUser).
- Event Log provider may require elevation to register or use the event source ("App-Health-Check"). If enabling fails, the function logs an error and continues with file logging.
- The JSON file provider is configured with:
  - PSFramework.Logging.LogFile.FileType = 'json'
  - PSFramework.Logging.LogFile.JsonNoComma = $false
  - PSFramework.Logging.LogFile.JsonNoEmptyFirstLine = $true
- Informational message verbosity is adjusted depending on -EmitForSolarWinds.
- The function writes no objects; it operates by side effect (PSFramework configuration and provider state).

.LINK
Set-PSFConfig
Set-PSFLoggingProvider
Write-PSFMessage
Write-AppLog
PSFramework on GitHub: https://github.com/PowershellFrameworkCollective/psframework
#>

function Start-AppHealthLogging {
    param (
        [Parameter(Mandatory)][string]$LogFileDirectory,
        [Parameter(Mandatory)][string]$LogFileName,
        [switch]$EmitForSolarWinds,
        [switch]$UseEventLog,
        [string]$Timestamp
    )
    # Ensure log directory exists before trying to write to it.
    $null = New-Item -Path $LogFileDirectory -ItemType Directory -Force -ErrorAction SilentlyContinue
    if (-not $Timestamp) {$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'}
    $fullLogPath = Join-Path -Path (Resolve-Path $LogFileDirectory) -ChildPath "$($LogFileName)_$($timestamp).log.json"
    # Set params at module scope for consumption by Stop-AppHealthLogging
    $script:LogFileDirectory = $LogFileDirectory
    $script:LogFileName      = $LogFileName
    $script:Timestamp        = $Timestamp
    $script:FullLogPath      = $FullLogPath
    $script:UseEventLog      = $UseEventLog

    # Configure the log providers
    Set-PSFConfig -FullName 'PSFramework.Logging.LogFile.FilePath' -Value $FullLogPath
    Set-PSFConfig -FullName 'PSFramework.Logging.LogFile.FileType' -Value 'json'
    Set-PSFConfig -FullName 'PSFramework.Logging.LogFile.JsonNoComma' -Value $false
    Set-PSFConfig -FullName 'PSFramework.Logging.LogFile.JsonNoEmptyFirstLine' -Value $true
    Set-PSFConfig -FullName 'PSFramework.Logging.EventLog.Source' -Value 'App-Health-Check'
    Set-PSFConfig -FullName 'PSFramework.Logging.EventLog.NumericTagAsID' -Value $true # The key to custom Event IDs

    # Settings to silence output for running with EmitForSolarWinds
    if ($EmitForSolarWinds) {
        Set-PSFConfig -FullName 'PSFramework.Message.Info.Maximum' -Value 1
    } else {
        Set-PSFConfig -FullName 'PSFramework.Message.Info.Maximum' -Value 3
    }


    # Enable the log providers
    Set-PSFLoggingProvider -Name 'logfile' -Enabled $true -Wait
    if ($UseEventLog) {
        # This is wrapped in case this is gated by admin priveleges
        try {
            Set-PSFLoggingProvider -Name 'eventlog' -Enabled $true -Wait
        } catch {
            Write-AppLog -Level Error -Message "Unable to enable EventLog provider. Continuing with JSON file provider." -Exception $_.Exception
        }   
    }
}