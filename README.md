# Enterprise Application Health Toolkit

A comprehensive, enterprise-ready PowerShell monitoring framework for HTTP/HTTPS endpoint health checks and TLS certificate expiration tracking. Designed as a lightweight, zero-dependency engine for automated self-healing runbooks and monitoring workflows.

---

## 🎯 Overview

This toolkit provides production-grade monitoring capabilities with structured JSON logging, Windows Event Log integration, self-healing notifications (Microsoft Teams), and state-based alerting with intelligent cadence controls. Built for Platform and Systems Engineers who need reliable, maintainable monitoring infrastructure that integrates seamlessly with existing enterprise tooling (SolarWinds, SCOM, Azure Monitor, etc.).

### Key Features

- **HTTP/HTTPS Health Checks**: Multi-threaded endpoint monitoring with latency tracking and retry logic
- **TLS Certificate Monitoring**: Automated certificate expiration detection with configurable notification windows
- **Structured Logging**: JSON-based logs with PSFramework integration and optional Windows Event Log mirroring
- **Smart Alerting**: State-based notifications with cadence controls, consecutive-failure thresholds, and recovery alerts
- **Self-Healing Integration**: Built-in Microsoft Teams webhook support for automated incident response
- **SolarWinds/SCOM Ready**: Optimized output modes for enterprise monitoring platforms
- **Zero External Dependencies**: Self-contained execution with no cloud service requirements

---

## 📁 Repository Structure

```
AppHealth-Toolkit/
├── src/
│   └── AppHealth.Common/          # Core PowerShell module
│       ├── AppHealth.Common.psd1  # Module manifest
│       ├── AppHealth.Common.psm1  # Module loader
│       ├── public/                # Public functions (exported)
│       └── private/               # Internal helper functions
├── scripts/
│   ├── Invoke-HttpHealthCheck.ps1 # HTTP health check orchestrator
│   └── Invoke-TlsHealthCheck.ps1  # TLS certificate check orchestrator
├── config/
│   ├── config.json                # Runtime configuration (URLs, hosts)
│   └── static.config.json         # Static defaults (event IDs, log levels)
├── tests/                         # Unit tests (Pester) - for future implementation
└── README.md                      # This file
```

---

## 🔧 The Engine: AppHealth.Common Module

The `AppHealth.Common` module is the core engine providing reusable functions for health monitoring and logging:

### Capabilities

- **Structured Logging**: `Write-AppLog`, `Start-AppHealthLogging`, `Stop-AppHealthLogging`
  - JSON file output with timestamps and correlation IDs
  - Optional Windows Event Log mirroring with custom event IDs
  - PSFramework integration for flexible logging providers
  
- **HTTP Health Checks**: `Invoke-AppHttpChecks`
  - Parallel execution (PowerShell 7+) for high-performance checks
  - Automatic retry logic with configurable timeout
  - Latency tracking and status code validation
  
- **TLS Certificate Checks**: `Test-TlsCertificates`
  - Certificate retrieval and expiration calculation
  - Parallel host scanning with throttle limits
  - Issuer and subject metadata extraction
  
- **Notification Functions**: `Send-HttpTeamsAlert`, `Send-CertTeamsAlert`
  - Adaptive Cards formatted for Microsoft Teams
  - Webhook-based delivery with error handling
  
- **Helper Functions**: `Resolve-AppHealthPath`, `Invoke-WithRetry`
  - Path resolution relative to script locations
  - Generic retry wrapper with exponential backoff

### Module Installation

```powershell
# Option 1: Import directly from repository
Import-Module .\src\AppHealth.Common\AppHealth.Common.psd1

# Option 2: Install to PowerShell module path (for persistent use)
# PowerShell 7+
$target = "$HOME\Documents\PowerShell\Modules\AppHealth.Common"
Copy-Item -Recurse -Force .\src\AppHealth.Common $target
Import-Module AppHealth.Common

# Windows PowerShell 5.1
$target = "$HOME\Documents\WindowsPowerShell\Modules\AppHealth.Common"
Copy-Item -Recurse -Force .\src\AppHealth.Common $target
Import-Module AppHealth.Common
```

---

## ⚙️ Configuration

### Runtime Configuration (`config/config.json`)

Defines the targets for health checks:

```json
{
  "email": {
    "to": "",
    "from": "healthcheck-monitor@example.com",
    "smtpServer": "smtp.example.com"
  },
  "httpChecks": [
    "https://example.org/health",
    "https://www.contoso.com/api/status"
  ],
  "certificateChecks": [
    "example.org",
    "www.contoso.com"
  ]
}
```

- **httpChecks**: Array of URLs to test via HTTP GET requests
- **certificateChecks**: Array of hostnames (port 443 assumed) for TLS checks
- **email**: Reserved for future SMTP notification support

### Static Configuration (`config/static.config.json`)

Defines logging behavior and event IDs for Windows Event Log integration:

```json
{
  "eventIdTable": {
    "ScriptStart": 1000,
    "ScriptEndSuccess": 1001,
    "ScriptEndFailure": 1002,
    "ConfigLoaded": 1003,
    "AllHttpChecksComplete": 2000,
    "HttpCheckFailed": 2001,
    ...
  },
  "logDefaults": {
    "Message": "",
    "Level": "Verbose",
    "Tag": ""
  }
}
```

---

## 🚀 Usage

### HTTP Health Checks

**Basic Execution:**
```powershell
# Run with repository defaults
pwsh -File .\scripts\Invoke-HttpHealthCheck.ps1
```

**With Self-Notifications (Teams Webhook):**
```powershell
pwsh -File .\scripts\Invoke-HttpHealthCheck.ps1 `
  -SelfNotify `
  -TeamsWebhookUrl 'https://outlook.office.com/webhook/YOUR_WEBHOOK' `
  -HttpConsecutiveFailureThreshold 3 `
  -HttpNotificationCadenceMinutes 60 `
  -NotifyHttpRecoveries
```

**SolarWinds/SCOM Integration Mode:**
```powershell
pwsh -File .\scripts\Invoke-HttpHealthCheck.ps1 `
  -EmitForSolarWinds `
  -LogFileDirectory .\logs\http `
  -FailureJsonDirectory .\logs\http\failures
```

**Key Parameters:**
- `-SelfNotify`: Enable automatic Teams notifications
- `-HttpConsecutiveFailureThreshold`: Number of consecutive failures before alerting (default: 1)
- `-HttpNotificationCadenceMinutes`: Minimum minutes between alerts for same URL (default: 60)
- `-NotifyHttpRecoveries`: Send recovery notifications when URLs return to healthy state
- `-UseEventLog`: Mirror logs to Windows Event Log
- `-EmitForSolarWinds`: Optimize output for monitoring platform ingestion

### TLS Certificate Checks

**Basic Execution:**
```powershell
# Run with repository defaults
pwsh -File .\scripts\Invoke-TlsHealthCheck.ps1
```

**With Expiration Window and Notifications:**
```powershell
pwsh -File .\scripts\Invoke-TlsHealthCheck.ps1 `
  -SelfNotify `
  -TeamsWebhookUrl 'https://outlook.office.com/webhook/YOUR_WEBHOOK' `
  -CertNotificationWindowDays 30
```

**Key Parameters:**
- `-CertNotificationWindowDays`: Days before expiration to trigger alerts (default: 30)
- `-SelfNotify`: Enable automatic Teams notifications for expiring certificates
- `-UseEventLog`: Mirror logs to Windows Event Log
- `-EmitForSolarWinds`: Optimize output for monitoring platform ingestion

---

## 📅 Scheduling with Windows Task Scheduler

For continuous monitoring, schedule the scripts to run at regular intervals:

### Setup Instructions

1. **Open Task Scheduler** → Create Task
2. **General Tab**:
   - Name: `AppHealth - HTTP Monitoring`
   - Run whether user is logged on or not
   - Run with highest privileges (if using Event Log)
3. **Triggers Tab**:
   - New → Daily
   - Repeat task every: `5 minutes` (or desired interval)
   - Duration: `Indefinitely`
4. **Actions Tab**:
   - Program/script: `pwsh.exe` (or `powershell.exe` for Windows PowerShell 5.1)
   - Arguments:
     ```
     -NoProfile -ExecutionPolicy Bypass -File "C:\Path\To\AppHealth-Toolkit\scripts\Invoke-HttpHealthCheck.ps1" -UseEventLog
     ```
5. **Conditions/Settings**: Configure per your environment requirements
6. **Save** and provide credentials when prompted

Repeat for TLS health checks with `Invoke-TlsHealthCheck.ps1`.

---

## 📋 Requirements

### Software Dependencies

- **PowerShell**: 7.0+ recommended (Windows PowerShell 5.1 supported with reduced parallelism)
- **PSFramework Module**: Install via PowerShell Gallery
  ```powershell
  Install-Module PSFramework -Scope CurrentUser -Force
  ```
- **Microsoft.PowerShell.SecretManagement** (optional): For webhook secret retrieval
  ```powershell
  Install-Module Microsoft.PowerShell.SecretManagement -Scope CurrentUser
  ```

### Permissions

- **Windows Event Log**: First-time registration of event sources may require administrator privileges
- **File System**: Write access to log directories (defaults to `scripts/logs/`)
- **Network**: Outbound HTTPS access to monitored endpoints and Teams webhook URLs

---

## 🎓 Use Cases

- **Automated Health Monitoring**: Schedule HTTP checks every 5 minutes for critical web applications
- **Certificate Lifecycle Management**: Daily TLS scans with 30-day advance notification
- **Self-Healing Workflows**: Integrate with Azure Automation or on-prem orchestration tools
- **Compliance Reporting**: JSON logs provide audit trail for availability and certificate status
- **Incident Response**: Teams notifications trigger on-call workflows with detailed failure context

---

## 🛠️ Troubleshooting

### No logs are being created
- Verify the `LogFileDirectory` exists and the run-as account has write permissions
- Check PSFramework module is installed: `Get-Module PSFramework -ListAvailable`

### Teams webhook not working
- Ensure the webhook URL is valid (test with `curl` or `Invoke-RestMethod`)
- If using SecretManagement, verify the secret exists: `Get-Secret -Name TeamsWebhook_CriticalAlerts`

### Event Log errors
- Run PowerShell as Administrator for first-time event source registration
- Verify Event Viewer → Application shows "App-Health-Check" source after first run

### TLS checks failing unexpectedly
- Current implementation enforces port 443; for custom ports, modify the script or module
- Firewalls/proxies may block outbound TLS handshakes; verify network connectivity

---

## 📝 Exit Codes

Both scripts use standard exit codes for automation integration:

- **0**: Success (all checks passed or no actionable failures)
- **1**: Failure (one or more checks failed, or a fatal error occurred)

Use these codes in Task Scheduler triggers or CI/CD pipelines for conditional logic.

---

## 📄 License

This project is provided as-is for educational and professional portfolio purposes. Feel free to adapt for your own use.

---

## 🤝 Contributing

This is a personal portfolio project, but suggestions and improvements are welcome. Please open an issue or submit a pull request.

---

## 📧 Contact

**Author**: Jamey Walker  
**Portfolio Repository**: [AppHealth-Toolkit](https://github.com/yourusername/AppHealth-Toolkit)

---

## 🔗 Related Resources

- [PSFramework Documentation](https://psframework.org/)
- [Microsoft Teams Incoming Webhooks](https://learn.microsoft.com/en-us/microsoftteams/platform/webhooks-and-connectors/how-to/add-incoming-webhook)
- [PowerShell Parallel Processing](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/foreach-object)
