<#
.SYNOPSIS
Executes TLS certificate health checks defined in repository configuration, writes structured logs, optionally sends Teams notifications, and supports SolarWinds output.

.DESCRIPTION
Invoke-TlsHealthCheck.ps1 orchestrates TLS certificate checks using the AppHealth.Common module. It:
- Loads static settings (event IDs, log defaults) and runtime config (list of hosts to check).
- Prunes old JSON log files based on retention policy.
- Initializes PSFramework logging (JSON file and optionally Windows Event Log).
- Runs certificate retrieval via Test-TlsCertificates and logs per-host results.
- Identifies certificates expiring within CertNotificationWindowDays.
- Optionally sends Microsoft Teams alerts for expiring certificates.
- In SolarWinds mode, emits "Statistic" and "Message" lines to stdout and minimizes log noise.
- Exits with code 1 when any notifications are warranted (i.e., expiring within the window); 0 otherwise.

Default paths are resolved relative to $PSScriptRoot, making the script self-contained within this repository layout.

.PARAMETER LogRetentionDays
Number of days to retain JSON log files (matching "<LogFileName>*.log.json" in LogFileDirectory). Older files are pruned at script start. Default: 30.

.PARAMETER CertNotificationWindowDays
Threshold (in days) for considering a certificate as requiring notification. Certificates with DaysRemaining less than or equal to this value are included in notifications. Default: 30.

.PARAMETER LogFileDirectory
Directory for JSON logs produced by PSFramework. If not provided, defaults to "$PSScriptRoot\logs\tls". The directory is created if necessary.

.PARAMETER LogFileName
Base name for the JSON log file; the actual file name includes a timestamp suffix. Default: "TlsHealth".

.PARAMETER ConfigFilePath
Path to the runtime configuration JSON (contains the list of hosts and other settings). If not provided, the script resolves to "<repo-root>\config\config.json".

.PARAMETER FailureJsonDirectory
Directory in which to write a per-run JSON payload for expiring certificates (used for external integrations). Defaults to "$PSScriptRoot\logs\tls\failures".

.PARAMETER TeamsWebhookUrl
Microsoft Teams incoming webhook URL for self-notifications. If omitted and not in SolarWinds mode, the script attempts to retrieve the secret named "TeamsWebhook_CriticalAlerts" via Microsoft.PowerShell.SecretManagement.

.PARAMETER UseEventLog
Enable the PSFramework Event Log provider (in addition to JSON file logging). May require administrative privileges to register the event source.

.PARAMETER EmitForSolarWinds
Optimizes output for SolarWinds SAM:
- Reduces informational log verbosity.
- Emits "Statistic.Label", "Statistic", and "Message" lines to stdout summarizing counts and pointing to the failure payload.
- Write-AppLog coerces levels for consistent ingestion unless -PreserveLevel is used in individual log calls.

.PARAMETER SelfNotify
When set, the script sends a Teams notification (using TeamsWebhookUrl) for the set of certificates expiring within the window.

.INPUTS
None. This script does not accept pipeline input.

.OUTPUTS
None. The script writes logs and, in SolarWinds mode, emits summary lines to stdout. It sets the process exit code to 0 (no expiring certs within window) or 1 (one or more expiring certs or a fatal error).

.EXAMPLES
Example 1: Run with repository defaults
pwsh -File .\scripts\core\Invoke-TlsHealthCheck.ps1

Example 2: SolarWinds mode with explicit directories
pwsh -File .\scripts\core\Invoke-TlsHealthCheck.ps1 `
  -EmitForSolarWinds `
  -LogFileDirectory .\scripts\core\logs\tls `
  -FailureJsonDirectory .\scripts\core\logs\tls\failures

Example 3: Notify for certificates expiring within 14 days
pwsh -File .\scripts\core\Invoke-TlsHealthCheck.ps1 `
  -SelfNotify `
  -TeamsWebhookUrl 'https://outlook.office.com/webhook/...' `
  -CertNotificationWindowDays 14

Example 4: Override config path and retention
pwsh -File .\scripts\core\Invoke-TlsHealthCheck.ps1 `
  -ConfigFilePath .\config\config.json `
  -LogRetentionDays 14

.NOTES
- Dependencies: PSFramework (logging), AppHealth.Common (module with core functions), Microsoft.PowerShell.SecretManagement (optional; used to resolve Teams webhook if not provided).
- Logging:
  - JSON file path: <LogFileDirectory>\<LogFileName>_<timestamp>.log.json
  - Event source: "App-Health-Check" (when UseEventLog is enabled).
- Configuration:
  - The script reads the "certificateChecks" array from config.json to obtain the host list.
- Notification payload:
  - Written to FailureJsonDirectory as "<COMPUTERNAME>_<runId>.json"; includes key fields such as HostName, DaysRemaining, Thumbprint, NotAfter, and issuer details.
- SolarWinds output:
  - Statistic.Label/Statistic pairs: certNotifyNow (to be notified now), certInWindow (expiring within window).
  - Message includes runId, detailPath, nextExpireDays, and expired count.
- Exit codes:
  - 0: No certificates require notification and no fatal errors.
  - 1: One or more certificates require notification, or a fatal error occurred.
- Trust validation:
  - Underlying Test-TlsCertificates retrieves certificate metadata without validating trust or hostname; it is intended for inventory/expiration monitoring.

.LINK
Test-TlsCertificates
Start-AppHealthLogging
Write-AppLog
Wait-PSFMessage
PSFramework: https://github.com/PowershellFrameworkCollective/psframework
#>
[CmdletBinding()]
param (
    # Config
    [int]$LogRetentionDays = 30,
    [int]$CertNotificationWindowDays = 30,

    # Paths
    [string]$LogFileDirectory,
    [string]$LogFileName,
    [string]$ConfigFilePath,
    [string]$FailureJsonDirectory,

    # Notification and cadence config
    [string]$TeamsWebhookUrl,
    [switch]$UseEventLog,
    [switch]$EmitForSolarWinds,
    [switch]$SelfNotify = $false
)

function Invoke-TlsHealthCheck {
    [CmdletBinding()]
    param (
        # Config
        [int]$CertNotificationWindowDays,
        [int]$LogRetentionDays,
        # Paths
        [string]$LogFileDirectory,
        [string]$LogFileName,
        [string]$ConfigFilePath,
        [string]$FailureJsonDirectory,
        # Notification settings
        [string]$TeamsWebhookUrl,
        [switch]$UseEventLog,
        [switch]$EmitForSolarWinds,
        [switch]$SelfNotify
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
            $LogFileDirectory = Resolve-AppHealthPath -PathType Logs -AppName 'tls' -StartPath $PSScriptRoot
        }
        if (-not $LogFileName)          {$LogFileName = "TlsHealth"}
        if (-not $ConfigFilePath)       {
            $ConfigFilePath = Join-Path $PSScriptRoot "..\config\config.json"
            }
        if (-not $FailureJsonDirectory) {$FailureJsonDirectory = Join-Path $PSScriptRoot "logs\tls\failures"}
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

        Write-AppLog -Level 'Host' -Tag $script:eventIdTable.ScriptStart -Message "Script 'Invoke-TlsHealthCheck.ps1' starting with config loaded at $($ConfigFilePath)."
        
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
            $script:certChecks = $config.certificateChecks
        }
        catch {
            Write-AppLog -Level Error -Tag $script:eventIdTable.ConfigLoadFailed -Message "A critical prerequisite failed. Script will terminate." -Exception $_.Exception
            throw "Prerequisite check failed." 
        }

        # Initialize script-wide flags for tracking status for SolarWinds.
        $script:scriptHasFailures = $false
    }

    process {
        #========================================= TLS Handshakes ================================================#
        $renewList                = @()
        $certResults              = @()
        $certResults = Test-TlsCertificates -HostList $script:certChecks -Port 443 -ThrottleLimit 10 -RetryCount 1 -TimeoutSec 10
        $renewList = $certResults | Where-Object { $_.Success -and $_.DaysRemaining -le $CertNotificationWindowDays }
        # This assignment needs to change when cert policies are implemented
        $notifyList = $renewList
        Write-AppLog -Level Host -Tag $script:eventIdTable.AllCertChecksComplete -Message "Certificate check completed for $($script:certChecks.Count) domains."

        # Compute notifications if needed and update stateLookup with 'now' for those thumbprints
        if ($renewList) {
            foreach ($cert in $renewList) {
                Write-AppLog -Level Verbose -Tag $script:eventIdTable.CertExpiringNotify -Message "Certificate expiring soon for $($cert.HostName). Days Remaining: $($cert.DaysRemaining)" -Target $cert
            }
            if ($notifyList -and $SelfNotify -and $TeamsWebhookUrl) {
                Write-AppLog -Level Host -Tag $script:eventIdTable.CertExpiringNotify -Message "$($notifyList.Count) items require a renewal notification."
                try {
                    Send-CertTeamsAlert -TeamsWebhookUrl $TeamsWebhookUrl -CertificateObjects $notifyList
                    Write-AppLog -Level Host -Tag $script:eventIdTable.AlertSent -Message "Alert dispatched successfully for expiring certificates."
                } catch {
                    Write-AppLog -Level Error -Tag $script:eventIdTable.AlertSendFailed -Message "Failed to send alert for expiring certificates." -Exception $_.Exception
                }
            } 
        }

    }

    end {

        # Create Json failure payloads
        $certFail = @($notifyList).Count
        if ($certFail -gt 0) {
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
                    failureObject        = @($notifyList  | Select-Object HostName, DaysRemaining, Thumbprint, NotAfter, issuerCN)
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
            $certNotifyNow = @($notifyList).Count
            $certInWindow  = @($renewList).Count
            $successCerts  = @($certResults | Where-Object { $_.Success })
            $expiredCount  = @($successCerts | Where-Object { $_.DaysRemaining -le 0 }).Count
            $nextExpireDays = $null
            if ($successCerts.Count -gt 0) {
                $nextExpireDays = ($successCerts | Sort-Object DaysRemaining | Select-Object -First 1).DaysRemaining
            }
            Write-Host "Statistic.Label: certNotifyNow"
            Write-Host ("Statistic: {0}" -f $certNotifyNow)
            Write-Host "Statistic.Label: certInWindow"
            Write-Host ("Statistic: {0}" -f $certInWindow)
            $runId  = $Host.Runspace.InstanceId.Guid
            $poller = $env:COMPUTERNAME
            $detail = Join-Path $FailureJsonDirectory "$($poller)_$($runId).json"
            $nextVal = ($null -eq $nextExpireDays) ? 'NA' : $nextExpireDays
            Write-Host ("Message: runId={0} detailPath={1} nextExpireDays={2} expired={3}" -f $runId, $detail, $nextVal, $expiredCount)
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
        CertNotificationWindowDays          = $CertNotificationWindowDays
        LogRetentionDays                    = $LogRetentionDays
        # Paths
        LogFileDirectory                    = $LogFileDirectory
        LogFileName                         = $LogFileName
        ConfigFilePath                      = $ConfigFilePath
        FailureJsonDirectory                = $FailureJsonDirectory
        # Notification settings
        TeamsWebhookUrl                     = $TeamsWebhookUrl
        UseEventLog                         = $UseEventLog
        EmitForSolarwinds                   = $EmitForSolarWinds
        SelfNotify                          = $SelfNotify
    }

    Invoke-TlsHealthCheck @mainParams

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