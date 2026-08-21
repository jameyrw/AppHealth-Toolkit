function Send-TeamsAlert {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$TeamsWebhookUrl,
        [Parameter(Mandatory)][pscustomobject]$Payload
    )
    $json = $Payload | ConvertTo-Json -Depth 15
    Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body $json -ContentType 'application/json' -ErrorAction Stop
}