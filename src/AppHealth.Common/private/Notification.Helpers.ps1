function New-CertAlertBody {
    [CmdletBinding()]
    [OutputType([string])]
    param (
        [PSCustomObject[]]$CertificateObjects 
    )
    # Build body with all certs within the renewal period
    $bodyLines = @("Alert: Certificates are near expiring for the following domains:")
    $bodyLines += "Cert Check Origin: $($env:COMPUTERNAME)"
    $bodyLines += ""
    
    foreach ($obj in $CertificateObjects) {
        $bodyLines += "Domain: $($obj.HostName)"
        $bodyLines += "  - Subject: $($obj.Subject)"
        $bodyLines += "  - Issuer: $($obj.Issuer)"
        $bodyLines += "  - Expires: $($obj.NotAfter)"
        $bodyLines += "  - DaysRemaining: $($obj.DaysRemaining)"
        $bodyLines += "  - Thumbprint: $($obj.Thumbprint)"
        $bodyLines += ""
    }

    return ($bodyLines -join "`n")
}

function Send-CertEmailAlert {
    [CmdletBinding()]
    param(
        [string[]]$EmailTo,
        [string]$EmailFrom,
        [string]$SmtpServer,
        [PSCustomObject[]]$CertificateObjects 
    )
    
    $body = New-CertAlertBody -CertificateObjects $CertificateObjects
    
    $sendMailMessageSplat = @{
        From       = $EmailFrom
        To         = $EmailTo
        Subject    = "CERT RENEWAL NOTICE - $($CertificateObjects.Count) certs need attention."
        SmtpServer = $SmtpServer
        Body       = $body
        UseSsl     = $true
    }
    
    try {
        Send-MailMessage @sendMailMessageSplat
    } catch {
        throw
    }
    
}

function New-CertAlertPayload {
    [CmdletBinding()]
    [OutputType([PSCustomObject])] # The output is a complex PowerShell object, not a simple string.
    param (
        [PSCustomObject[]]$CertificateObjects 
    )

    # --- Step 1: Build the BODY of the Adaptive Card ---
    # This is an array of elements that will be displayed on the card.
    $cardBodyElements = @()

    # Add a title text block with a warning color
    $cardBodyElements += [PSCustomObject]@{
        type    = "TextBlock"
        text    = "Alert: Certificates Nearing Expiration"
        weight  = "Bolder"
        size    = "Medium"
        color   = "Warning" # Makes the text stand out (e.g., orange)
    }

    # Add the origin computer info in a FactSet for nice alignment
    $cardBodyElements += [PSCustomObject]@{
        type      = "FactSet"
        separator = $true # Adds a dividing line
        facts     = @(
            [PSCustomObject]@{
                title = "Origin"
                value = $env:COMPUTERNAME
            }
        )
    }

    # Add a container for each certificate to group its information visually
    foreach ($obj in $CertificateObjects) {
        
        $cardBodyElements += [PSCustomObject]@{
            type      = "Container"
            separator = $true
            items     = @(
                # Domain name as a sub-header
                [PSCustomObject]@{
                    type   = "TextBlock"
                    text   = $obj.HostName
                    weight = "Bolder"
                    size   = "Default"
                }
                # Use a FactSet for neatly aligned key-value pairs
                [PSCustomObject]@{
                    type  = "FactSet"
                    facts = @(
                        [PSCustomObject]@{
                            title = "Expires"
                            value = "$($obj.NotAfter) ($($obj.DaysRemaining) days left)"
                        }
                        [PSCustomObject]@{
                            title = "Subject"
                            value = $obj.Subject
                        }
                        [PSCustomObject]@{
                            title = "Issuer"
                            value = $obj.Issuer
                        }
                        [PSCustomObject]@{
                            title = "Thumbprint"
                            value = $obj.Thumbprint
                        }
                    )
                }
            )
        }
    }

    # --- Step 2: Assemble the full Adaptive Card CONTENT ---
    # This wraps the body in the required card structure.
    $adaptiveCardContent = [PSCustomObject]@{
        '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
        type      = "AdaptiveCard"
        version   = "1.4"
        body      = $cardBodyElements
    }

    # --- Step 3: Create the final PAYLOAD that the Power Automate trigger expects ---
    # This wraps the card in the required 'attachments' array.
    $finalPayload = [PSCustomObject]@{
        type        = "message" # This property is required by the schema
        attachments = @(
            [PSCustomObject]@{
                contentType = "application/vnd.microsoft.card.adaptive"
                content     = $adaptiveCardContent
            }
        )
    }

    # Return the complete, complex object, ready to be converted to JSON
    return $finalPayload
}


function Send-CertTeamsAlert {
    param (
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [string]$TeamsWebhookUrl,
        [PSCustomObject[]]$CertificateObjects 
    )
    $body = New-CertAlertPayload -CertificateObjects $CertificateObjects | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body $body -ContentType "application/json"
}



function New-HttpAlertBody {
    [OutputType([string])]
    param (
        [PSCustomObject[]]$ResponseObjects 
    )
    # Build body with all failures
    $bodyLines = @("Alert: Web requests have failed for the following URLs:")
    $bodyLines += "Web Request Origin: $($env:COMPUTERNAME)"
    $bodyLines += ""
    
    foreach ($obj in $ResponseObjects) {
        $bodyLines += "URL: $($obj.Url)"
        $bodyLines += "  - StatusCode: $($obj.StatusCode)"
        $bodyLines += "  - StatusDescription: $($obj.StatusDescription)"
        $bodyLines += "  - Latency: $($obj.Latency)ms"
        $bodyLines += ""
    }

    return ($bodyLines -join "`n")
}
function Send-HttpEmailAlert {
    [CmdletBinding()]
    param(
        [string[]]$EmailTo,
        [string]$EmailFrom,
        [string]$SmtpServer,
        [PSCustomObject[]]$ResponseObjects 
    )
    
    $body = New-HttpAlertBody -ResponseObjects $ResponseObjects
    
    $sendMailMessageSplat = @{
        From       = $EmailFrom
        To         = $EmailTo
        Subject    = "WEBREQUEST FAILURES DETECTED - $($ResponseObjects.Count) site(s) down"
        SmtpServer = $SmtpServer
        Body       = $body
        UseSsl     = $true
    }
    
    try {
        Send-MailMessage @sendMailMessageSplat
    } catch {
        throw
    }
}

function New-HttpAlertPayload {
    [CmdletBinding()]
    [OutputType([PSCustomObject])] # The output is now a complex object
    param (
        [PSCustomObject[]]$ResponseObjects 
    )

    # --- Step 1: Build the BODY of the Adaptive Card ---
    # This is an array of elements that will be displayed on the card.
    $cardBodyElements = @()

    # Add a title text block
    $cardBodyElements += [PSCustomObject]@{
        type = "TextBlock"
        text = "Alert: Web Service Failures Detected"
        weight = "Bolder"
        size = "Medium"
    }

    # Add the origin computer info
    $cardBodyElements += [PSCustomObject]@{
        type = "TextBlock"
        text = "Origin: $($env:COMPUTERNAME)"
        isSubtle = $true
        separator = $true # Adds a nice dividing line
    }

    # Add a text block for each failure
    foreach ($obj in $ResponseObjects) {
        $failureText = "URL: $($obj.Url)`n- StatusCode: $($obj.StatusCode)`n- StatusDescription: $($obj.StatusDescription)`n- Latency: $($obj.Latency)ms"
        
        $cardBodyElements += [PSCustomObject]@{
            type = "TextBlock"
            text = $failureText
            wrap = $true # Ensures long text wraps correctly
        }
    }

    # --- Step 2: Assemble the full Adaptive Card CONTENT ---
    # This wraps the body in the required card structure.
    $adaptiveCardContent = [PSCustomObject]@{
        '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
        type      = "AdaptiveCard"
        version   = "1.4"
        body      = $cardBodyElements
    }

    # --- Step 3: Create the final PAYLOAD that the trigger expects ---
    # This wraps the card in the required 'attachments' array.
    $finalPayload = [PSCustomObject]@{
        type        = "message" # This property is required by the schema
        attachments = @(
            [PSCustomObject]@{
                contentType = "application/vnd.microsoft.card.adaptive"
                content     = $adaptiveCardContent
            }
        )
    }

    # Return the complete, complex object
    return $finalPayload
}

function Send-HttpTeamsAlert {
    param (
        [Parameter(Mandatory=$true)][ValidateNotNullOrEmpty()]
        [string]$TeamsWebhookUrl,
        [PSCustomObject[]]$ResponseObjects 
    )
    $body = New-HttpAlertPayload -ResponseObjects $ResponseObjects | ConvertTo-Json -Depth 10
    Invoke-RestMethod -Uri $TeamsWebhookUrl -Method Post -Body $body -ContentType "application/json"
}