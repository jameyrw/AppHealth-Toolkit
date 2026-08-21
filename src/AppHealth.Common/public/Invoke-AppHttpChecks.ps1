<#
.SYNOPSIS
Performs HTTP health checks against one or more URLs with retries and optional parallelism.

.DESCRIPTION
Invoke-AppHttpChecks sends HTTP requests to each URL in UrlList using Invoke-WebRequest, measures latency, and captures the final HTTP status. It implements an exponential backoff retry policy with jitter and, on PowerShell 7+, can run requests concurrently via ForEach-Object -Parallel.

The function emits a result object per URL indicating success or failure; it does not throw for individual request failures. On success, each result includes StatusCode, StatusDescription, and Latency (ms). On failure, StatusCode is set when available from the response (or -1 if no response was received), and ErrorMessage contains the exception message. Attempts indicates how many tries were performed for that URL. Date lets you apply a consistent timestamp across all results.

On PowerShell 7 or later, when ThrottleLimit > 1, requests are executed in parallel and output order may differ from input order. On Windows PowerShell 5.1/PowerShell 6, or when ThrottleLimit -le 1, requests are executed sequentially.

.PARAMETER UrlList
One or more absolute HTTP/HTTPS URLs to test.

.PARAMETER Date
The timestamp to include in each result object. Defaults to the time Invoke-AppHttpChecks is called. Use this to stamp a consistent time across a batch.

.PARAMETER TimeoutSec
Per-attempt request timeout in seconds. Default is 30.

.PARAMETER Method
HTTP method to use (e.g., GET, HEAD). Default is GET.
Note: This function does not expose a request body parameter for methods such as POST/PUT.

.PARAMETER Headers
Optional hashtable of HTTP headers to include with each request.
Example: @{ 'User-Agent' = 'HealthCheck/1.0'; 'Accept' = '*/*' }

.PARAMETER MaximumRedirection
Maximum number of HTTP redirects to follow automatically. Applied only when greater than 0; otherwise, Invoke-WebRequest defaults are used. Default is 5.

.PARAMETER ThrottleLimit
Maximum number of concurrent requests when running in PowerShell 7+ (ForEach-Object -Parallel). Set to 1 to force sequential execution. Default is 10. Ignored on Windows PowerShell 5.1/PowerShell 6 where the function always runs sequentially.

.PARAMETER RetryCount
Number of retries after the initial attempt. Total attempts = RetryCount + 1. Default is 2.

.PARAMETER InitialDelayMs
Initial delay before the first retry, in milliseconds. Default is 250.

.PARAMETER BackoffFactor
Multiplier applied to the retry delay for each subsequent retry (exponential backoff). Default is 2.0.

.PARAMETER MaxDelayMs
Maximum per-retry delay, in milliseconds, used as an upper bound after applying backoff. Default is 4000.

.PARAMETER JitterPct
Maximum additional random jitter, expressed as a fraction of the computed delay (for example, 0.2 = up to +20% extra). Default is 0.2.

.INPUTS
None. UrlList does not accept pipeline input.

.OUTPUTS
System.Management.Automation.PSCustomObject
Each object has the following properties:
- Url (string)
- StatusCode (int; -1 if not available)
- StatusDescription (string)
- Latency (int; elapsed milliseconds for the final attempt that produced the result)
- Date (datetime)
- Attempts (int; number of attempts performed)
- Success (bool)
- ErrorMessage (string; null on success)

.EXAMPLES
Example 1: Basic GET checks
PS> Invoke-AppHttpChecks -UrlList 'https://example.org','https://contoso.com'
PS> # Display a compact view
PS> Invoke-AppHttpChecks -UrlList 'https://example.org','https://contoso.com' |
>> Format-Table Url, StatusCode, Success, Latency

Example 2: Run in parallel (PowerShell 7+)
PS> Invoke-AppHttpChecks -UrlList (Get-Content .\urls.txt) -ThrottleLimit 20
# Note: Output order may not match input order.

Example 3: Use HEAD method with a custom timeout and headers
PS> $headers = @{ 'User-Agent' = 'AppHealth/1.0'; 'Accept' = '*/*' }
PS> Invoke-AppHttpChecks -UrlList 'https://example.org/health' -Method HEAD -TimeoutSec 10 -Headers $headers

Example 4: Tighter retry policy with more attempts
PS> Invoke-AppHttpChecks -UrlList 'https://api.example.com/ping' -RetryCount 4 -InitialDelayMs 200 -BackoffFactor 1.8 -MaxDelayMs 3000 -JitterPct 0.15

Example 5: Filter failures and export a report
PS> $results = Invoke-AppHttpChecks -UrlList (Get-Content .\urls.txt) -ThrottleLimit 30 -RetryCount 3
PS> $results | Where-Object { -not $_.Success } | Sort-Object Url |
>> Export-Csv .\http-check-failures.csv -NoTypeInformation

Example 6: Force sequential execution (e.g., for deterministic logs)
PS> Invoke-AppHttpChecks -UrlList (Get-Content .\urls.txt) -ThrottleLimit 1

.NOTES
- Cross-version behavior: On Windows PowerShell, the function adds -UseBasicParsing for compatibility. On PowerShell 7+, ForEach-Object -Parallel is used when ThrottleLimit > 1.
- Latency reflects only the attempt that produced the final result (successful or the last failure), not the cumulative time across all attempts.
- StatusCode is extracted from the HTTP response when available; if no response is received (e.g., DNS/connection errors), StatusCode is -1.
- The function does not throw for individual request failures; check the Success property to determine pass/fail.
- MaximumRedirection is only applied when greater than 0; otherwise, Invoke-WebRequest defaults are used.
- There is no parameter to disable TLS/SSL certificate validation.

.LINK
Invoke-WebRequest
ForEach-Object -Parallel
about_CommonParameters
#>

function Invoke-AppHttpChecks {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string[]]$UrlList,

        [datetime]$Date = (Get-Date),

        # HTTP behavior
        [int]$TimeoutSec = 30,
        [string]$Method = 'GET',
        [hashtable]$Headers,
        [int]$MaximumRedirection = 5,

        # Parallelism (PS 7+)
        [int]$ThrottleLimit = 10,

        # Retry policy (exponential backoff + jitter)
        [int]$RetryCount = 2,     # total attempts = RetryCount + 1
        [int]$InitialDelayMs = 250,
        [double]$BackoffFactor = 2.0,
        [int]$MaxDelayMs = 4000,
        [double]$JitterPct = 0.2
    )

    # Inner helper to perform a single attempt
    function Invoke-OneAttempt {
        param([string]$Url,[int]$TimeoutSec,[string]$Method,[hashtable]$Headers,[int]$MaximumRedirection)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            # Simple, cross-version: always use TimeoutSec
            $splat = @{ Uri = $Url; Method = $Method; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }

            if ($PSVersionTable.PSVersion.Major -lt 6) {
                $splat.UseBasicParsing = $true
            }
            if ($Headers) { $splat.Headers = $Headers }
            if ($MaximumRedirection -gt 0) { $splat.MaximumRedirection = $MaximumRedirection }

            $resp = Invoke-WebRequest @splat
            $sw.Stop()
            return [pscustomobject]@{
                Url               = $Url
                StatusCode        = [int]$resp.StatusCode
                StatusDescription = ($resp.StatusDescription ? $resp.StatusDescription : $resp.StatusCode.ToString())
                Latency           = $sw.ElapsedMilliseconds
                Success           = $true
                ErrorMessage      = $null
            }
        }
        catch {
            $sw.Stop()
            $code = -1
            $desc = $_.Exception.Message

            $respObj = $null
            if ($_.Exception.PSObject.Properties['Response']) {
                $respObj = $_.Exception.Response
            }

            if ($respObj -is [System.Net.Http.HttpResponseMessage]) {
                try { $code = [int]$respObj.StatusCode } catch {}
                if ($respObj.ReasonPhrase) { $desc = $respObj.ReasonPhrase }
            } elseif ($respObj -is [System.Net.HttpWebResponse]) {
                $code = [int]$respObj.StatusCode
                $desc = $respObj.StatusDescription
            } elseif ($_.Exception.PSObject.Properties['StatusCode']) {
                try { $code = [int]$_.Exception.StatusCode } catch {}
            }

            return [pscustomobject]@{
                Url               = $Url
                StatusCode        = $code
                StatusDescription = $desc
                Latency           = $sw.ElapsedMilliseconds
                Success           = $false
                ErrorMessage      = $_.Exception.Message
            }
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 7 -and $ThrottleLimit -gt 1) {
        # Parallel path: emit results, let the pipeline collect them
        $results = $UrlList | ForEach-Object -Parallel {
            # Capture external values via $using:
            $url                = $PSItem
            $TimeoutSec         = $using:TimeoutSec
            $Method             = $using:Method
            $Headers            = $using:Headers
            $MaximumRedirection = $using:MaximumRedirection
            $RetryCount         = $using:RetryCount
            $InitialDelayMs     = $using:InitialDelayMs
            $BackoffFactor      = $using:BackoffFactor
            $MaxDelayMs         = $using:MaxDelayMs
            $JitterPct          = $using:JitterPct
            $Date               = $using:Date

            # Local copy of helper (define inside each runspace)
            function Invoke-OneAttempt {
                param([string]$Url,[int]$TimeoutSec,[string]$Method,[hashtable]$Headers,[int]$MaximumRedirection)
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                try {
                    # Cross-version safe
                    $splat = @{ Uri = $Url; Method = $Method; ErrorAction = 'Stop'; TimeoutSec = $TimeoutSec }
                    if ($PSVersionTable.PSVersion.Major -lt 6) { $splat.UseBasicParsing = $true }
                    if ($Headers) { $splat.Headers = $Headers }
                    if ($MaximumRedirection -gt 0) { $splat.MaximumRedirection = $MaximumRedirection }
                    $resp = Invoke-WebRequest @splat
                    $sw.Stop()
                    return [pscustomobject]@{
                        Url               = $Url
                        StatusCode        = [int]$resp.StatusCode
                        StatusDescription = ($resp.StatusDescription ? $resp.StatusDescription : $resp.StatusCode.ToString())
                        Latency           = $sw.ElapsedMilliseconds
                        Success           = $true
                        ErrorMessage      = $null
                    }
                }
                catch {
                    $sw.Stop()
                    $code = -1
                    $desc = $_.Exception.Message

                    $respObj = $null
                    if ($_.Exception.PSObject.Properties['Response']) {
                        $respObj = $_.Exception.Response
                    }

                    if ($respObj -is [System.Net.Http.HttpResponseMessage]) {
                        try { $code = [int]$respObj.StatusCode } catch {}
                        if ($respObj.ReasonPhrase) { $desc = $respObj.ReasonPhrase }
                    } elseif ($respObj -is [System.Net.HttpWebResponse]) {
                        $code = [int]$respObj.StatusCode
                        $desc = $respObj.StatusDescription
                    } elseif ($_.Exception.PSObject.Properties['StatusCode']) {
                        try { $code = [int]$_.Exception.StatusCode } catch {}
                    }

                    return [pscustomobject]@{
                        Url               = $Url
                        StatusCode        = $code
                        StatusDescription = $desc
                        Latency           = $sw.ElapsedMilliseconds
                        Success           = $false
                        ErrorMessage      = $_.Exception.Message
                    }
                }
            }

            # Retry loop
            $allowed = $RetryCount + 1
            $last = $null
            for ($attempt = 1; $attempt -le $allowed; $attempt++) {
                $last = Invoke-OneAttempt -Url $url -TimeoutSec $TimeoutSec -Method $Method -Headers $Headers -MaximumRedirection $MaximumRedirection
                if ($last.Success) { break }
                if ($attempt -lt $allowed) { 
                    $delay  = [math]::Min($MaxDelayMs, [int]([math]::Round($InitialDelayMs * [math]::Pow($BackoffFactor, $attempt - 1))))
                    $jitter = [int]([math]::Round($delay * $JitterPct * (Get-Random -Minimum 0.0 -Maximum 1.0)))
                    Start-Sleep -Milliseconds ($delay + $jitter)
                }
            }

            # Emit result for this URL
            [pscustomobject]@{
                Url               = $last.Url
                StatusCode        = $last.StatusCode
                StatusDescription = $last.StatusDescription
                Latency           = $last.Latency
                Date              = $Date
                Attempts          = $attempt
                Success           = $last.Success
                ErrorMessage      = $last.ErrorMessage
            }
        } -ThrottleLimit $ThrottleLimit

        return $results
    }
    else {
        # Sequential fallback
        $out = New-Object System.Collections.Generic.List[object]
        foreach ($u in $UrlList) {
            $allowed = $RetryCount + 1
            $last = $null
            for ($attempt = 1; $attempt -le $allowed; $attempt++) {
                $last = Invoke-OneAttempt -Url $u -TimeoutSec $TimeoutSec -Method $Method -Headers $Headers -MaximumRedirection $MaximumRedirection
                if ($last.Success) { break }
                if ($attempt -lt $allowed) { 
                    $delay  = [math]::Min($MaxDelayMs, [int]([math]::Round($InitialDelayMs * [math]::Pow($BackoffFactor, $attempt - 1))))
                    $jitter = [int]([math]::Round($delay * $JitterPct * (Get-Random -Minimum 0.0 -Maximum 1.0)))
                    Start-Sleep -Milliseconds ($delay + $jitter)
                }
            }
            $out.Add([pscustomobject]@{
                Url               = $last.Url
                StatusCode        = $last.StatusCode
                StatusDescription = $last.StatusDescription
                Latency           = $last.Latency
                Date              = $Date
                Attempts          = $attempt
                Success           = $last.Success
                ErrorMessage      = $last.ErrorMessage
            }) | Out-Null
        }
        return $out
    }
}