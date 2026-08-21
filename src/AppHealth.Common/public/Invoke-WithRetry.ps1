function Invoke-WithRetry {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [scriptblock]$Action,

        [int]$MaxAttempts = 3,
        [int]$InitialDelaySeconds = 2,     # base backoff
        [double]$BackoffFactor = 2.0,      # exponential backoff
        [int]$MaxDelaySeconds = 30
    )
    $attempt = 0
    $lastErr = $null
    while ($attempt -lt $MaxAttempts) {
        try {
            $attempt++
            return & $Action
        } catch {
            $lastErr = $_
            if ($attempt -ge $MaxAttempts) { break }
            $delay = [math]::Min([int]($InitialDelaySeconds * [math]::Pow($BackoffFactor, $attempt - 1)), $MaxDelaySeconds)
            # add small jitter (+/- 20%)
            $rand = Get-Random -Minimum -0.2 -Maximum 0.2
            $sleep = [int]([math]::Max(1, $delay * (1 + $rand)))
            Start-Sleep -Seconds $sleep
        }
    }
    throw $lastErr
}