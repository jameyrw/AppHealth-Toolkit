<#
.SYNOPSIS
Retrieves TLS certificate details from one or more hosts with retries and optional parallelism.

.DESCRIPTION
Test-TlsCertificates opens a TCP connection to each host and initiates a TLS handshake using SslStream to retrieve the remote certificate. It reports certificate metadata (Subject, Issuer, Thumbprint, NotAfter) and a computed DaysRemaining value. The command uses an exponential backoff retry policy with jitter and, on PowerShell 7+, can run host checks concurrently via ForEach-Object -Parallel.

Important:
- This command does not validate the certificate chain or hostname. It deliberately accepts any certificate in order to retrieve it (validation callback always returns $true).
- Success = $true means the function connected and retrieved a certificate; it does not imply the certificate is valid or trusted.
- DaysRemaining is the floor of (NotAfter - now). On failure, NotAfter is $null and DaysRemaining is [int]::MinValue.

On PowerShell 7 or later, when ThrottleLimit > 1, hosts are processed in parallel and output order may differ from input order. On Windows PowerShell 5.1/PowerShell 6, or when ThrottleLimit -le 1, hosts are processed sequentially.

.PARAMETER HostList
One or more host names or IP addresses to test. Host names are recommended so that SNI (Server Name Indication) can select the correct certificate on the target.

.PARAMETER Port
TCP port to connect to. Default is 443.

.PARAMETER TimeoutSec
Connection and stream I/O timeout in seconds. Default is 10.

.PARAMETER SslProtocols
TLS protocol(s) to permit for the handshake. Default is Tls12.
You may specify combined flags if supported by your PowerShell/.NET runtime, for example:
[Tls12, Tls13] on newer runtimes.

.PARAMETER ThrottleLimit
Maximum number of concurrent host checks on PowerShell 7+ (ForEach-Object -Parallel). Set to 1 to force sequential execution. Default is 10. Ignored on Windows PowerShell 5.1/PowerShell 6 where the function runs sequentially.

.PARAMETER RetryCount
Number of retries after the initial attempt. Total attempts = RetryCount + 1. Default is 1.

.PARAMETER InitialDelayMs
Initial delay before the first retry, in milliseconds. Default is 250.

.PARAMETER BackoffFactor
Multiplier applied to the retry delay for each subsequent retry (exponential backoff). Default is 2.0.

.PARAMETER MaxDelayMs
Maximum per-retry delay, in milliseconds, used as an upper bound after applying backoff. Default is 4000.

.PARAMETER JitterPct
Maximum additional random jitter, expressed as a fraction of the computed delay (for example, 0.2 = up to +20% extra). Default is 0.2.

.INPUTS
None. HostList does not accept pipeline input.

.OUTPUTS
System.Management.Automation.PSCustomObject
Each object has the following properties:
- HostName (string)
- Subject (string)
- Issuer (string)
- Thumbprint (string)
- NotAfter (datetime)
- DaysRemaining (int; [int]::MinValue on failure)
- Success (bool)
- ErrorMessage (string; null on success)
- Attempts (int; number of attempts performed)

.EXAMPLES
Example 1: Check a few hosts with default settings
PS> Test-TlsCertificates -HostList 'api.contoso.com','login.microsoftonline.com' |
>> Format-Table HostName, NotAfter, DaysRemaining, Success

Example 2: Run in parallel on PowerShell 7+
PS> $hosts = Get-Content .\hosts.txt
PS> Test-TlsCertificates -HostList $hosts -ThrottleLimit 20

Example 3: Include non-standard port and increase timeout
PS> Test-TlsCertificates -HostList 'internal-gw.contoso.local' -Port 8443 -TimeoutSec 20

Example 4: Allow newer protocol versions (if supported)
PS> $proto = [System.Security.Authentication.SslProtocols]::Tls12 -bor `
>>          [System.Security.Authentication.SslProtocols]::Tls13
PS> Test-TlsCertificates -HostList 'service.example.com' -SslProtocols $proto

Example 5: Find certificates expiring within 14 days
PS> Test-TlsCertificates -HostList (Get-Content .\hosts.txt) -ThrottleLimit 30 |
>> Where-Object { $_.Success -and $_.DaysRemaining -lt 14 } |
>> Sort-Object DaysRemaining |
>> Select-Object HostName, NotAfter, DaysRemaining

Example 6: Tighter retry policy
PS> Test-TlsCertificates -HostList 'flaky.example.com' -RetryCount 3 -InitialDelayMs 200 -BackoffFactor 1.8 -MaxDelayMs 3000 -JitterPct 0.1

.NOTES
- Security: The certificate validation callback always returns $true, so chain and hostname validation are bypassed. This is intentional to retrieve certificate metadata even when the certificate is invalid or mismatched. Do not use this function to assert trust; use it to inventory and monitor expiration.
- Hostname vs IP: Passing a DNS name enables SNI during AuthenticateAsClient and is more likely to retrieve the intended certificate. An IP address may return a default certificate.
- Failures: On connection/protocol failures, Success = $false, ErrorMessage contains the exception message, NotAfter = $null, DaysRemaining = [int]::MinValue.
- Parallel behavior requires PowerShell 7+. On earlier versions, the function always runs sequentially.

.LINK
ForEach-Object -Parallel
about_CommonParameters
System.Net.Security.SslStream
System.Security.Authentication.SslProtocols
#>

function Test-TlsCertificates {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$HostList,

        [int]$Port = 443,
        [int]$TimeoutSec = 10,
        [System.Security.Authentication.SslProtocols]$SslProtocols = [System.Security.Authentication.SslProtocols]::Tls12,

        # Parallelism (PS 7+)
        [int]$ThrottleLimit = 10,

        # Retry policy (exponential backoff + jitter)
        [int]$RetryCount = 1,      # total attempts = RetryCount + 1
        [int]$InitialDelayMs = 250,
        [double]$BackoffFactor = 2.0,
        [int]$MaxDelayMs = 4000,
        [double]$JitterPct = 0.2
    )

    # Helper used in sequential path
    function Invoke-OneCertAttempt {
        param([string]$HostName,[int]$Port,[int]$TimeoutSec,[System.Security.Authentication.SslProtocols]$SslProtocols)
        $tcp = $null
        $ssl = $null
        try {
            $tcp = [System.Net.Sockets.TcpClient]::new()
            $task = $tcp.ConnectAsync($HostName, $Port)
            if (-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSec))) {
                throw "Timeout connecting to $($HostName):$($Port) after $TimeoutSec seconds."
            }
            $validationCallback = { param($cbSender, $cert, $chain, $errors) return $true }
            $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $validationCallback)
            $ssl.ReadTimeout  = $TimeoutSec * 1000
            $ssl.WriteTimeout = $TimeoutSec * 1000
            $ssl.AuthenticateAsClient($HostName, $null, $SslProtocols, $false)
            $remote = $ssl.RemoteCertificate
            if (-not $remote) { throw "No certificate presented by $($HostName):$($Port)." }
            $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($remote)
            $notAfter = $x.NotAfter
            $days = [int][math]::Floor(($notAfter - (Get-Date)).TotalDays)
            [pscustomobject]@{
                HostName      = $HostName
                Subject       = $x.Subject
                Issuer        = $x.Issuer
                Thumbprint    = $x.Thumbprint
                NotAfter      = $notAfter
                DaysRemaining = $days
                Success       = $true
                ErrorMessage  = $null
            }
        }
        catch {
            [pscustomobject]@{
                HostName      = $HostName
                Subject       = $null
                Issuer        = $null
                Thumbprint    = $null
                NotAfter      = $null
                DaysRemaining = [int]::MinValue
                Success       = $false
                ErrorMessage  = $_.Exception.Message
            }
        }
        finally {
            if ($ssl) { $ssl.Dispose() }
            if ($tcp) { $tcp.Dispose() }
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $ThrottleLimit -gt 1) {
        # Parallel path: emit one result per host; the pipeline collects them
        $results = $HostList | ForEach-Object -Parallel {
            # Bring in external values
            $hostName        = $PSItem
            $Port            = $using:Port
            $TimeoutSec      = $using:TimeoutSec
            $SslProtocols    = $using:SslProtocols
            $RetryCount      = $using:RetryCount
            $InitialDelayMs  = $using:InitialDelayMs
            $BackoffFactor   = $using:BackoffFactor
            $MaxDelayMs      = $using:MaxDelayMs
            $JitterPct       = $using:JitterPct

            # Define helper locally inside each runspace
            function Invoke-OneCertAttempt {
                param([string]$HostName,[int]$Port,[int]$TimeoutSec,[System.Security.Authentication.SslProtocols]$SslProtocols)
                $tcp = $null
                $ssl = $null
                try {
                    $tcp = [System.Net.Sockets.TcpClient]::new()
                    $task = $tcp.ConnectAsync($HostName, $Port)
                    if (-not $task.Wait([TimeSpan]::FromSeconds($TimeoutSec))) {
                        throw "Timeout connecting to $($HostName):$($Port) after $TimeoutSec seconds."
                    }
                    $validationCallback = { param($cbSender, $cert, $chain, $errors) return $true }
                    $ssl = [System.Net.Security.SslStream]::new($tcp.GetStream(), $false, $validationCallback)
                    $ssl.ReadTimeout  = $TimeoutSec * 1000
                    $ssl.WriteTimeout = $TimeoutSec * 1000
                    $ssl.AuthenticateAsClient($HostName, $null, $SslProtocols, $false)
                    $remote = $ssl.RemoteCertificate
                    if (-not $remote) { throw "No certificate presented by $($HostName):$($Port)." }
                    $x = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($remote)
                    $notAfter = $x.NotAfter
                    $days = [int][math]::Floor(($notAfter - (Get-Date)).TotalDays)
                    [pscustomobject]@{
                        HostName      = $HostName
                        Subject       = $x.Subject
                        Issuer        = $x.Issuer
                        Thumbprint    = $x.Thumbprint
                        NotAfter      = $notAfter
                        DaysRemaining = $days
                        Success       = $true
                        ErrorMessage  = $null
                    }
                }
                catch {
                    [pscustomobject]@{
                        HostName      = $HostName
                        Subject       = $null
                        Issuer        = $null
                        Thumbprint    = $null
                        NotAfter      = $null
                        DaysRemaining = [int]::MinValue
                        Success       = $false
                        ErrorMessage  = $_.Exception.Message
                    }
                }
                finally {
                    if ($ssl) { $ssl.Dispose() }
                    if ($tcp) { $tcp.Dispose() }
                }
            }

            # Retry loop
            $allowed = $RetryCount + 1
            $last = $null
            for ($attempt = 1; $attempt -le $allowed; $attempt++) {
                $last = Invoke-OneCertAttempt -HostName $hostName -Port $Port -TimeoutSec $TimeoutSec -SslProtocols $SslProtocols
                if ($last.Success) { break }
                if ($attempt -lt $allowed) { 
                    $delay  = [math]::Min($MaxDelayMs, [int]([math]::Round($InitialDelayMs * [math]::Pow($BackoffFactor, $attempt - 1))))
                    $jitter = [int]([math]::Round($delay * $JitterPct * (Get-Random -Minimum 0.0 -Maximum 1.0)))
                    Start-Sleep -Milliseconds ($delay + $jitter)
                }
            }

            # Emit normalized result for this host
            $last | Add-Member -NotePropertyName Attempts -NotePropertyValue $attempt -Force
            $last
        } -ThrottleLimit $ThrottleLimit

        return $results
    }
    else {
        # Sequential fallback (PS5 or ThrottleLimit <= 1)
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($h in $HostList) {
            $allowed = $RetryCount + 1
            $last = $null
            for ($attempt = 1; $attempt -le $allowed; $attempt++) {
                $last = Invoke-OneCertAttempt -HostName $h -Port $Port -TimeoutSec $TimeoutSec -SslProtocols $SslProtocols
                if ($last.Success) { break }
                if ($attempt -lt $allowed) { 
                    $delay  = [math]::Min($MaxDelayMs, [int]([math]::Round($InitialDelayMs * [math]::Pow($BackoffFactor, $attempt - 1))))
                    $jitter = [int]([math]::Round($delay * $JitterPct * (Get-Random -Minimum 0.0 -Maximum 1.0)))
                    Start-Sleep -Milliseconds ($delay + $jitter)
                }
            }
            $last | Add-Member -NotePropertyName Attempts -NotePropertyValue $attempt -Force
            $out.Add($last) | Out-Null
        }
        return $out
    }
}