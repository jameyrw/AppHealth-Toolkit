<#
.SYNOPSIS
Executes HTTP health checks defined in repository configuration, writes structured logs, maintains per-URL alert state, optionally sends Teams notifications, and supports SolarWinds output.

.DESCRIPTION
Invoke-HttpHealthCheck.ps1 orchestrates HTTP endpoint checks using the AppHealth.Common module. It:
- Loads static settings (event IDs, log defaults) and runtime config (list of URLs to check).
- Prunes old JSON log files based on retention policy.
- Initializes PSFramework logging (JSON file and optionally Windows Event Log).
- Runs HTTP checks via Invoke-AppHttpChecks and logs per-URL results.
- Tracks consecutive failures per URL and enforces a notification cadence, persisting state to disk.
- Optionally sends Microsoft Teams alerts (failures and, optionally, recoveries).
- In SolarWinds mode, emits "Statistic" and "Message" lines to stdout and minimizes log noise.
- Exits with code 1 when any failures occur; 0 otherwise.

Default paths are resolved relative to $PSScriptRoot, making the script self-contained within this repository layout.

.PARAMETER LogRetentionDays
Number of days to retain JSON log files (matching "<LogFileName>*.log.json" in LogFileDirectory). Older files are pruned at script start. Default: 30.

.PARAMETER LogFileDirectory
Directory for JSON logs produced by PSFramework. If not provided, defaults to "$PSScriptRoot\logs\http". The directory is created if necessary.

.PARAMETER LogFileName
Base name for the JSON log file; the actual file name includes a timestamp suffix. Default: "HttpHealth".

.PARAMETER ConfigFilePath
Path to the runtime configuration JSON (contains the list of URLs and other settings consumed by this script). If not provided, the script resolves to "<repo-root>\config\config.json".

.PARAMETER FailureJsonDirectory
Directory in which to write a per-run JSON payload with details of failing URLs (used for external integrations). Defaults to "$PSScriptRoot\logs\http\failures".

.PARAMETER HttpStatePath
Path to the self-notification state file (JSON), tracking per-URL consecutive failures, cadence, and muted windows. Defaults to "$PSScriptRoot\state\http\http_state.json".

.PARAMETER TeamsWebhookUrl
Microsoft Teams incoming webhook URL for self-notifications. If omitted and not in SolarWinds mode, the script attempts to retrieve the secret named "TeamsWebhook_CriticalAlerts" via Microsoft.PowerShell.SecretManagement.

.PARAMETER UseEventLog
Enable the PSFramework Event Log provider (in addition to JSON file logging). May require administrative privileges to register the event source.

.PARAMETER EmitForSolarWinds
Optimizes output for SolarWinds SAM:
- Reduces informational log verbosity.
- Emits "Statistic.Label", "Statistic", and "Message" lines to stdout summarizing failures and pointing to the failure payload.
- Write-AppLog coerces levels for more consistent ingestion unless -PreserveLevel is used in individual log calls.

.PARAMETER SelfNotify
When set, the script sends self-notifications to Teams (using TeamsWebhookUrl) for URLs that meet the failure threshold and cadence criteria, and optionally sends recovery notifications.

.PARAMETER HttpConsecutiveFailureThreshold
Minimum number of consecutive failing runs for a given URL before a self-notification is sent. Default: 1.

.PARAMETER HttpNotificationCadenceMinutes
Minimum number of minutes between notifications for the same URL. Default: 60.

.PARAMETER NotifyHttpRecoveries
When set, sends a recovery notification once a previously alerted URL is no longer failing.

.INPUTS
None. This script does not accept pipeline input.

.OUTPUTS
None. The script writes logs and, in SolarWinds mode, emits summary lines to stdout. It sets the process exit code to 0 (success) or 1 (one or more failures or a fatal error).

.EXAMPLES
Example 1: Run with repository defaults
pwsh -File .\scripts\core\Invoke-HttpHealthCheck.ps1

Example 2: SolarWinds mode with explicit directories
pwsh -File .\scripts\core\Invoke-HttpHealthCheck.ps1 `
  -EmitForSolarWinds `
  -LogFileDirectory .\scripts\core\logs\http `
  -FailureJsonDirectory .\scripts\core\logs\http\failures

Example 3: Enable Event Log and Teams self-notifications with cadence
pwsh -File .\scripts\core\Invoke-HttpHealthCheck.ps1 `
  -UseEventLog `
  -SelfNotify `
  -TeamsWebhookUrl 'https://outlook.office.com/webhook/...' `
  -HttpConsecutiveFailureThreshold 3 `
  -HttpNotificationCadenceMinutes 120

Example 4: Override config and state path for a test run
pwsh -File .\scripts\core\Invoke-HttpHealthCheck.ps1 `
  -ConfigFilePath .\config\config.json `
  -HttpStatePath .\scripts\core\state\http\http_state.json `
  -LogRetentionDays 14

.NOTES
- Dependencies: PSFramework (logging), AppHealth.Common (module with core functions), Microsoft.PowerShell.SecretManagement (optional; used to resolve Teams webhook if not provided).
- Logging:
  - JSON file path: <LogFileDirectory>\<LogFileName>_<timestamp>.log.json
  - Event source: "App-Health-Check" (when UseEventLog is enabled).
- State file schema (per URL):
  - Url, FirstDetected, LastNotified, Consecutive, MutedUntil
- Failures payload:
  - Written to FailureJsonDirectory as "<COMPUTERNAME>_<runId>.json"; includes Url, StatusCode, StatusDescription, Latency.
- Exit codes:
  - 0: No failures detected and no fatal errors.
  - 1: One or more failures, or a fatal error occurred.
- Parallel HTTP execution is handled inside the module function Invoke-AppHttpChecks (PowerShell 7+).

.LINK
Invoke-AppHttpChecks
Start-AppHealthLogging
Write-AppLog
Wait-PSFMessage
PSFramework: https://github.com/PowershellFrameworkCollective/psframework
#>
[CmdletBinding()]
param (
    # Config
    [int]$LogRetentionDays = 30,

    # Paths
    [string]$LogFileDirectory,
    [string]$LogFileName,
    [string]$ConfigFilePath,
    [string]$FailureJsonDirectory,
    [string]$HttpStatePath,

    # Notification and cadence config
    [string]$TeamsWebhookUrl,
    [switch]$UseEventLog,
    [switch]$EmitForSolarWinds,
    [switch]$SelfNotify = $false,
    [int]$HttpConsecutiveFailureThreshold = 1,
    [int]$HttpNotificationCadenceMinutes = 60,
    [switch]$NotifyHttpRecoveries
)

function Invoke-HttpHealthCheck {
    [CmdletBinding()]
    param (
        # Config
        [int]$LogRetentionDays,
        # Paths
        [string]$LogFileDirectory,
        [string]$LogFileName,
        [string]$ConfigFilePath,
        [string]$FailureJsonDirectory,
        [string]$HttpStatePath,
        # Notification settings
        [string]$TeamsWebhookUrl,
        [switch]$UseEventLog,
        [switch]$EmitForSolarWinds,
        [switch]$SelfNotify,
        [int]$HttpConsecutiveFailureThreshold,
        [int]$HttpNotificationCadenceMinutes,
        [switch]$NotifyHttpRecoveries
    )
    begin {
        # Load modules
        try {
            Import-Module 'Microsoft.PowerShell.SecretManagement' -ErrorAction Stop -Force -Verbose:$false
            Import-Module 'PSFramework' -ErrorAction Stop -Force -Verbose:$false
            $modulePath = Join-Path $PSScriptRoot "..\src\AppHealth.Common\AppHealth.Common.psd1"
            Import-Module $modulePath -ErrorAction Stop -Force -Verbose:$false
        }
        catch {
            # This is a fatal, non-recoverable error. Logging isn't even available yet.
            Write-Error "FATAL: A required module is missing or failed to load. Error: $($_.Exception.Message)"
            exit 1
        }

        # Resolve path defaults
        if (-not $LogFileDirectory)     {
            $LogFileDirectory = Resolve-AppHealthPath -PathType Logs -AppName 'http' -StartPath $PSScriptRoot
        }
        if (-not $LogFileName)          {$LogFileName = "HttpHealth"}
        if (-not $ConfigFilePath)       {
            $ConfigFilePath = Join-Path $PSScriptRoot "..\config\config.json"
            }
        if (-not $FailureJsonDirectory) {$FailureJsonDirectory = Join-Path $PSScriptRoot "logs\http\failures"}
        if (-not $HttpStatePath)        {
            $HttpStatePath = Join-Path $LogFileDirectory "state\http_state.json"
        }
        $staticConfigPath = Join-Path "$PSScriptRoot" "..\config\static.config.json"


        # Load static config
        try {
            $staticConfig = Get-Content $staticConfigPath | ConvertFrom-Json -ErrorAction Stop
        } catch {
            throw "FATAL: Unable to load static config from static.config.json. Tool integrity may have been compromised."
        }
        # Script scope defaults
        $script:EmitForSolarWinds = [bool]$EmitForSolarWinds
        $script:isLoggingInitialized = $false
        $script:eventIdTable = $staticConfig.eventIdTable

        # This is the default splat that gets passed to Write-PSFMessage in order to write logs with the logging framework
        # We coerce it to a hashtable so we can easily clone it and modify defaults dynamically
        $script:logDefaults = @{}
        $staticConfig.logDefaults.PSObject.Properties | ForEach-Object {
            $script:LogDefaults[$_.Name] = $_.Value
        }
        $script:LogDefaults['FunctionName'] = $MyInvocation.MyCommand.Name

        # Prune logs - execute before initiating logging to avoid problems with file locking
        try {
            if (Test-Path $LogFileDirectory) {
                $pruneFailures = 0
                $logCutoffDate = (Get-Date).Date.AddDays(-$LogRetentionDays)
                Get-ChildItem $LogFileDirectory -File -Filter "$LogFileName*.log.json" -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt $logCutoffDate } |
                    ForEach-Object {
                        try {
                            Remove-Item -LiteralPath $_.FullName -Force -ErrorAction Stop
                        } catch {
                            $pruneFailures++
                        }
                    }
                if ($pruneFailures -gt 0) {
                    if (-not $EmitForSolarWinds) {
                        Write-Warning "$pruneFailures errors detected while removing old logs. Continuing run."
                    }
                }
            }
        } catch {
            if (-not $EmitForSolarWinds) {
                Write-Warning "Error pruning logs. Continuing run. $_"
            }
        }

        # --- Logging Dependencies ---
        try {
            $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
            Start-AppHealthLogging -LogFileName:$LogFileName -LogFileDirectory:$LogFileDirectory -UseEventLog:$UseEventLog -EmitForSolarWinds:$EmitForSolarWinds -Timestamp:$timestamp
            $script:isLoggingInitialized = $true
        }
        catch {
            # If this fails, we can't use PSFramework to log, so we use Write-Error and throw.
            Write-Error "FATAL: Failed to initialize the PSFramework logging system. Error: $($_.Exception.Message)"
            throw "Logging initialization failed."
        }

        Write-AppLog -Level 'Host' -Tag $script:eventIdTable.ScriptStart -Message "Script 'Invoke-HttpHealthCheck.ps1' starting with config loaded at $($ConfigFilePath)."
        
        # --- Application dependencies and config ---        
        try {

            Write-AppLog -Level Verbose -Message "Loading configuration." -Tag $script:eventIdTable.ConfigLoaded
            
            # Try to resolve Teams Webhook if not yet passed in
            if ((-not $TeamsWebhookUrl) -and (-not $EmitForSolarWinds) ) {
                try {
                    $TeamsWebhookUrl = Get-Secret -Name 'TeamsWebhook_CriticalAlerts' -AsPlainText -ErrorAction Stop
                } catch {
                    Write-AppLog -Level Error -Message "No Teams webhook passed in. No notifications will be sent." -Exception $_.Exception -Tag $script:eventIdTable.DependencyMissing
                }

            }
            
            # Validate config file path
            $testConfigPath = Test-Path $ConfigFilePath -PathType Leaf
            if (-not $testConfigPath) {
                Write-AppLog -Level Error -Tag $script:eventIdTable.ConfigLoadFailed -Message "ConfigFilePath failed validation."
                throw
            }


            # Load in config
            $script:config = Get-Content $ConfigFilePath -Raw | ConvertFrom-Json -ErrorAction Stop
            $script:httpChecks = $config.httpChecks
        }
        catch {
            Write-AppLog -Level Error -Tag $script:eventIdTable.ConfigLoadFailed -Message "A critical prerequisite failed. Script will terminate." -Exception $_.Exception
            throw "Prerequisite check failed." 
        }

        # http self-alert state (loaded on first use in process)
        $script:httpStateLoaded = $false
        $script:httpState       = @()
        # Initialize script-wide flags for tracking status for SolarWinds.
        $script:scriptHasFailures = $false
    }

    process {
        $failureList = @()
        $date = Get-Date
        #========================================== HTTP Calls ========================================================================================#
        $responseData = Invoke-AppHttpChecks -UrlList $script:httpChecks -Date $Date
        $failureList = $responseData | Where-Object { ($_.StatusCode -lt 200) -or ($_.StatusCode -gt 399) }
        Write-AppLog -Level Host -Tag $script:eventIdTable.AllHttpChecksComplete -Message "HTTP check completed for $($responseData.Count) URLs"

        # ---------------- HTTP SELF-ALERT CADENCE ----------------
        # New state model (array of objects): Url, LastNotified, FirstDetected, Consecutive, MutedUntil
        # 1) Load HTTP state (in begin; shown here inline for clarity)
        if (-not $script:httpStateLoaded) {
            if (Test-Path $HttpStatePath) {
                $tmp = Get-Content $HttpStatePath -Raw | ConvertFrom-Json
                $script:httpState = @()
                if ($null -ne $tmp) { $script:httpState = @($tmp) }
            } else {
                $script:httpState = @()
            }
            $script:httpStateLoaded = $true
        }

        # 2) Build lookup from state
        $httpIndex = @{}
        foreach ($entry in $script:httpState) { $httpIndex[$entry.Url] = $entry }

        # 3) Current failures per URL (group if the same URL appears multiple times)
        $now = Get-Date
        $currentFailUrls = @(
            $failureList |
            Group-Object Url |
            ForEach-Object {
                [pscustomobject]@{
                    Url    = $_.Name
                    Count  = $_.Count
                    Sample = $_.Group | Select-Object -First 1
                }
            }
        )

        # 4) Evaluate failures with cadence and consecutive threshold
        $toNotifyHttp       = New-Object System.Collections.Generic.List[psobject]
        $pendingNotifyUrls  = New-Object System.Collections.Generic.List[string]

        foreach ($f in $currentFailUrls) {
            $url   = $f.Url
            $state = $httpIndex[$url]
            if (-not $state) {
                # first time we see this URL failing
                $state = [pscustomobject]@{
                    Url           = $url
                    FirstDetected = $now
                    LastNotified  = [datetime]::MinValue
                    Consecutive   = 0
                    MutedUntil    = $null  # set manually to a future time to mute a URL
                }
                $script:httpState += $state
                $httpIndex[$url]   = $state
            }

            # Skip if muted for maintenance
            if ($state.MutedUntil -and $now -lt [datetime]$state.MutedUntil) { continue }

            # Increment consecutive failures
            $state.Consecutive++

            $thresholdReached = ($state.Consecutive -ge $HttpConsecutiveFailureThreshold)
            $pastCadence      = ($state.LastNotified -lt $now.AddMinutes(-$HttpNotificationCadenceMinutes))

            if ($thresholdReached -and $pastCadence) {
                # This URL needs a new notification in this run
                $toNotifyHttp.Add($f.Sample)      | Out-Null
                $pendingNotifyUrls.Add($url)      | Out-Null
            }
        }

        # 5) Detect recoveries (URLs that were failing but are no longer failing this run)
        $failedUrlsNow = $currentFailUrls.Url
        $recovered = @(
            $script:httpState |
            Where-Object { $_.Consecutive -gt 0 -and ($failedUrlsNow -notcontains $_.Url) }
        )

        # Optionally send recovery alerts (once) and reset state
        $toNotifyRecoveries = @()
        if ($NotifyHttpRecoveries) {
            foreach ($r in $recovered) {
                # Only recover if we actually alerted at least once (LastNotified ever set)
                if ($r.LastNotified -gt [datetime]::MinValue) {
                    $toNotifyRecoveries += $r.Url
                }
                # reset counters after noting recovery
                $r.Consecutive  = 0
                $r.FirstDetected = $null
                $r.LastNotified  = [datetime]::MinValue
            }
        } else {
            # no recovery notifications; just clear counters
            foreach ($r in $recovered) {
                $r.Consecutive  = 0
                $r.FirstDetected = $null
                $r.LastNotified  = [datetime]::MinValue
            }
        }

        # 6) Send self-notifications using the cadence-filtered list
        if ($SelfNotify -and $TeamsWebhookUrl) {
            # Failures (cadence-filtered)
            if ($toNotifyHttp.Count -gt 0) {
                try {
                    # Build a payload just from cadence-approved failures
                    Send-HttpTeamsAlert -TeamsWebhookUrl $TeamsWebhookUrl -ResponseObjects $toNotifyHttp

                    # Mark as notified only on success
                    foreach ($u in $pendingNotifyUrls) {
                        if ($httpIndex.ContainsKey($u)) { $httpIndex[$u].LastNotified = $now }
                    }
                    Write-AppLog -Level Host -Tag $script:eventIdTable.AlertSent -Message "HTTP self-alert dispatched for $($toNotifyHttp.Count) URL(s) (cadence-filtered)."
                } catch {
                    Write-AppLog -Level Error -Tag $script:eventIdTable.AlertSendFailed -Message "Failed to send HTTP self-alert(s)." -Exception $_.Exception
                }
            }

            # Recoveries
            if ($toNotifyRecoveries.Count -gt 0) {
                try {
                    # Shape recovery objects for the existing failure card
                    $recoveryObjs = $toNotifyRecoveries | ForEach-Object {
                        [pscustomobject]@{
                            Url               = $_
                            StatusCode        = 200
                            StatusDescription = 'Recovered'
                            Latency           = 0
                        }
                    }
                    Send-HttpTeamsAlert -TeamsWebhookUrl $TeamsWebhookUrl -ResponseObjects $recoveryObjs
                    Write-AppLog -Level Host -Tag $script:eventIdTable.AlertSent -Message "HTTP recovery self-alert dispatched for $($toNotifyRecoveries.Count) URL(s)."
                } catch {
                    Write-AppLog -Level Error -Tag $script:eventIdTable.AlertSendFailed -Message "Failed to send HTTP recovery self-alert(s)." -Exception $_.Exception
                }
            }
        }
        # Log response data indvidiaully to JSON
        if ($responseData) {
            foreach ($response in $responseData) {
                Write-AppLog -Level Verbose -Message "HTTP response data recorded for $($response.URL)" -Target $response -Tag $script:eventIdTable.HttpCheckComplete
            }
        }
    }

    end {
        # Update Http notification state
        $pruneCutoff = (Get-Date).AddDays(-90)
        $script:httpState = @(
            $script:httpState | Where-Object {
                $_.Consecutive -gt 0 -or
                $_.LastNotified -gt [datetime]::MinValue -or
                ($_.FirstDetected -and $_.FirstDetected -gt $pruneCutoff)
            }
        )

        try {
            $dir = Split-Path -Path $HttpStatePath -Parent
            if ($dir) { New-Item -Path $dir -ItemType Directory -Force | Out-Null }

            # Ensure we always have something to serialize
            $obj = $script:httpState
            if ($null -eq $obj) { $obj = @() }

            # Serialize to a string; fall back to '[]' if empty
            $json = $obj | ConvertTo-Json -Depth 6
            if ([string]::IsNullOrWhiteSpace($json)) { $json = '[]' }

            # Atomic write
            $tmp = "$HttpStatePath.tmp"
            Set-Content -Path $tmp -Value $json -Encoding UTF8 -Force -ErrorAction Stop

            # Only move if the tmp exists to avoid throw in rare cases
            if (Test-Path -LiteralPath $tmp) {
                Move-Item -LiteralPath $tmp -Destination $HttpStatePath -Force
                Write-AppLog -Level Verbose -Message "HTTP state file '$HttpStatePath' updated."
            } else {
                # Fallback: write directly if tmp missing for any reason
                Set-Content -Path $HttpStatePath -Value $json -Encoding UTF8 -Force
                Write-AppLog -Level Warning -Tag $script:eventIdTable.StateUpdateFailed -Message "Temp file missing; wrote HTTP state directly to '$HttpStatePath'."
            }
        }
        catch {
            Write-AppLog -Level Error -Tag $script:eventIdTable.StateUpdateFailed -Message "Error updating HTTP state file." -Exception $_.Exception
        }

        # Create Json failure payloads
        $httpFail = @($failureList).Count
        if ($httpFail -gt 0) {
            $script:scriptHasFailures = $true
            try {
                # Drop detailed Json payload in the failure directory with detailed failure information
                $runid = $Host.Runspace.InstanceId.Guid
                $poller = $env:COMPUTERNAME
                $when   = (Get-Date).ToUniversalTime()
                $payload = [pscustomobject]@{
                    runId                = $runId
                    poller               = $poller
                    when                 = $when
                    component            = $MyInvocation.MyCommand.Name
                    failureObject        = @($failureList | Select-Object Url, StatusCode, StatusDescription, Latency)
                }
                New-Item -ItemType Directory -Path $FailureJsonDirectory -Force | Out-Null
                $detailPath = Join-Path $FailureJsonDirectory "$($poller)_$($runId).json"

                # Atomic write
                $tmp = "$detailPath.tmp"
                $payload | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
                Move-Item -Path $tmp -Destination $detailPath -Force
            } catch {
                Write-AppLog -Level 'Error' -Tag $script:eventIdTable.FileAccessError -Message "Error writing detailed failure payload to target directory." -Exception $_.Exception
            }
        }
        
        # --- Final Summary for SolarWinds (STDOUT) ---
        if ($EmitForSolarWinds) {
            $httpFail      = @($responseData | Where-Object { $_.StatusCode -lt 200 -or $_.StatusCode -ge 400 }).Count
            Write-Host "Statistic.Label: httpFail"
            Write-Host ("Statistic: {0}" -f $httpFail)
            $runId  = $Host.Runspace.InstanceId.Guid
            $poller = $env:COMPUTERNAME
            $detail = Join-Path $FailureJsonDirectory "$($poller)_$($runId).json"
            Write-Host ("Message: runId={0} detailPath={1}" -f $runId, $detail)
        }
        

        # --- Final Log Message & Stop Logging ---
        if ($script:scriptHasFailures) {
            Write-AppLog -Level Warning -Tag $script:eventIdTable.ScriptEndFailure -Message "Script finished with one or more failures."
        } else {
            Write-AppLog -Level Host -Tag $script:eventIdTable.ScriptEndSuccess -Message "Script finished successfully." 
        }

        Stop-AppHealthLogging
    }
}

# =========================================================================================
# SCRIPT EXECUTION WRAPPER
# =========================================================================================
try {
    # Explicitly pass args from exposed param block to the function
    $mainParams = @{
        # Config
        LogRetentionDays                    = $LogRetentionDays
        # Paths
        LogFileDirectory                    = $LogFileDirectory
        LogFileName                         = $LogFileName
        ConfigFilePath                      = $ConfigFilePath
        FailureJsonDirectory                = $FailureJsonDirectory
        HttpStatePath                       = $HttpStatePath
        # Notification settings
        TeamsWebhookUrl                     = $TeamsWebhookUrl
        UseEventLog                         = $UseEventLog
        EmitForSolarwinds                   = $EmitForSolarWinds
        SelfNotify                          = $SelfNotify
        HttpNotificationCadenceMinutes      = $HttpNotificationCadenceMinutes
        HttpConsecutiveFailureThreshold     = $HttpConsecutiveFailureThreshold
        NotifyHttpRecoveries                = $NotifyHttpRecoveries
    }

    Invoke-HttpHealthCheck @mainParams

    if ($script:scriptHasFailures) {
        exit 1
    } else {
        exit 0
    }
}

catch {
    if ($script:isLoggingInitialized) {
        Write-AppLog -Level 'Error' -Message "Script terminated due to a fatal error in the wrapper." -Exception $_.Exception
    }
    else {
        Write-Error "Script terminated due to a FATAL error and logging was not available. Error: $($_.Exception.Message)"
    }
    exit 1
}