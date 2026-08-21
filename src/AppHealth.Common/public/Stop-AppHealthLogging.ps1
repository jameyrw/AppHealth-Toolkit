<#
.SYNOPSIS
Stops the PSFramework logging session, flushes pending messages, and finalizes the JSON log file.
.DESCRIPTION
Stop-AppHealthLogging cleanly shuts down the logging context established by Start-AppHealthLogging. It performs the following actions:
- Flushes the PSFramework message queue to ensure all pending logs are written to disk.
- Disables the 'logfile' and 'eventlog' providers to stop further logging.
- Post-processes the JSON log file. PSFramework appends individual JSON objects, which is not a valid JSON file structure. This function reads the log file and wraps the content in square brackets ([]) to transform it into a valid JSON array, making it easily parsable.

The function primarily relies on the configuration set by Start-AppHealthLogging. The parameters are optional and serve as fallbacks if the script-scoped state is unavailable.
.PARAMETER LogFileDirectory
An optional override for the log file's directory. If omitted, the function uses the context set by Start-AppHealthLogging.
.PARAMETER LogFileName
An optional override for the log file's base name. If omitted, the function uses the context set by Start-AppHealthLogging.
.PARAMETER Timestamp
An optional override for the timestamp used in the log file name. If omitted, the function uses the context set by Start-AppHealthLogging.
.INPUTS
None. Does not accept pipeline input.
.OUTPUTS
None. This command operates by side effect, modifying the log file and PSFramework provider state.
.EXAMPLES
Example 1: Stop logging in a standard session
# This is the most common use case. It relies on the context from Start-AppHealthLogging.
PS> Stop-AppHealthLogging

Example 2: Full start-to-stop logging workflow
PS> $ts = Get-Date -Format 'yyyyMMdd-HHmmss'
PS> Start-AppHealthLogging -LogFileDirectory 'C:\Logs\AppHealth' -LogFileName 'app-run' -Timestamp $ts
PS> Write-AppLog -Level Info -Message "Starting health checks..."
PS> # ... application logic runs here ...
PS> Write-AppLog -Level Info -Message "Health checks complete."
PS> Stop-AppHealthLogging
PS> # The file 'C:\Logs\AppHealth\app-run_20230101-120000.log.json' is now a valid JSON array.
.NOTES
- This function is designed to be the counterpart to Start-AppHealthLogging and should be called after it to ensure proper log file finalization.
- The JSON finalization step is critical for making the log file consumable by tools that expect a valid JSON array. If this step fails, a warning is displayed, but the raw log content remains.
- The function uses Wait-PSFMessage to block execution until all buffered log messages have been written, preventing data loss on exit.
.LINK
Start-AppHealthLogging
Set-PSFLoggingProvider
Wait-PSFMessage
#>
function Stop-AppHealthLogging {
    param (
        [string]$LogFileDirectory,
        [string]$LogFileName,
        [string]$Timestamp
    )
    # Grab script state that was set by Start-AppHealthLogging
    if (-not $FullLogPath)      {$FullLogPath = $script:FullLogPath}
    if (-not $Timestamp)        {$Timestamp = $script:Timestamp}

    # 'Stop' logging and flush logs by disabling providers
    Write-AppLog -Level Verbose -Message "Flushing log queue before shutdown."
    Wait-PSFMessage
    Set-PSFLoggingProvider -Name 'logfile' -Enabled $false -Wait
    if ($script:UseEventLog) {
        Set-PSFLoggingProvider -Name 'eventlog' -Enabled $false -Wait
    }

    # Convert our logs into valid json. By default PSFramework wants to append json. We just need to enclose []
    try {
        if (Test-Path $FullLogPath) {
            $content = Get-Content -Path $FullLogPath -Raw
            if ($content) {
                $fixed = $content.Trim()
                if (-not ($fixed.Startswith('[') -and $fixed.EndsWith(']'))) {
                    $fixed = "[`n$fixed`n]"
                }
                Set-Content -Path $FullLogPath -Value $fixed -Encoding UTF8
            }
        }
    } catch {
        Write-Warning "Post-processing JSON log failed: ($_.Exception.Message)"
    }

}

    