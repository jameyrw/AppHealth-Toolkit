<#
.SYNOPSIS
Writes a structured log entry via PSFramework with sensible defaults and optional SolarWinds-friendly formatting.

.DESCRIPTION
Write-AppLog is a thin wrapper around Write-PSFMessage that merges a set of default logging fields (LogDefaults) with any parameters you provide, then emits the log entry. It supports:
- Numeric Tag values (useful as Windows Event IDs when PSFramework eventlog provider uses NumericTagAsID = $true).
- Automatic level escalation to Error when logging an Exception (unless you explicitly set -Level).
- Optional SolarWinds mode (-EmitForSolarWinds) which:
  - Forces the effective Level to Verbose (unless -PreserveLevel).
  - Preserves the original level in Data.OriginalLevel.
  - Adds Data.EmitMode = 'SAM'.
  - Replaces raw Exception with a compact, structured summary (Message, Type, HResult, Source, and top stack frame) assigned to Target.

The function returns no output. It delegates to Write-PSFMessage and relies on the logging configuration initialized elsewhere (for example, Start-AppHealthLogging).

.PARAMETER Message
Text message to record.

.PARAMETER Tag
Numeric tag (1–65535). When the PSFramework eventlog provider is enabled with NumericTagAsID = $true, this becomes the Windows Event ID.

.PARAMETER Level
Log level. Default: Verbose.
Allowed values: Critical, Host, Output, Important, Significant, VeryVerbose, Verbose, SomewhatVerbose, System, Debug, InternalComment, Warning, Error.
If -Exception is provided and -Level is not, the effective level becomes Error (unless -EmitForSolarWinds with -PreserveLevel:$false, which forces Verbose).

.PARAMETER Target
An object to attach as additional context (appears as TargetObject in PSFramework logs). Ignored when -Exception is provided (exception takes precedence), except in SolarWinds mode where the exception summary is placed in Target.

.PARAMETER Exception
An exception to log. By default sets the effective level to Error unless you explicitly pass a -Level.
In SolarWinds mode (-EmitForSolarWinds and not -PreserveLevel), a condensed summary object is attached as Target instead of logging the raw Exception.

.PARAMETER FunctionName
Name of the function to attribute as the source (passed through to Write-PSFMessage, useful for origin tracking).

.PARAMETER PreserveLevel
When used with -EmitForSolarWinds, preserves your requested -Level instead of forcing Verbose.

.PARAMETER LogDefaults
Hashtable of default fields to start from. By default, uses $script:logDefaults.
Typical keys include:
- Level
- Message
- Tag
- Data (hashtable with custom fields)
Your explicit parameters override corresponding keys in LogDefaults. The hashtable is cloned internally so the original is not mutated.

.PARAMETER EmitForSolarWinds
Enables SolarWinds-friendly output:
- Sets Data.EmitMode = 'SAM'.
- Records Data.OriginalLevel = <your-level>.
- Forces effective Level = Verbose unless -PreserveLevel is specified.
- Converts -Exception into a compact summary attached as Target.

.INPUTS
None. This function does not accept pipeline input.

.OUTPUTS
None. Writes to PSFramework logging providers; returns no objects.

.EXAMPLES
Example 1: Simple verbose message
PS> Write-AppLog -Message 'Health check started.'

Example 2: Warning with a numeric tag (event ID)
PS> Write-AppLog -Level Warning -Tag 2001 -Message 'Latency exceeded threshold.'

Example 3: Log an exception (defaults level to Error)
PS> try {
>>   Invoke-WebRequest https://bad.host -TimeoutSec 5 -ErrorAction Stop
>> } catch {
>>   Write-AppLog -Exception $_.Exception -Message 'HTTP check failed' -Tag 5001
>> }

Example 4: Attach a target object for context
PS> $ctx = @{ Url = 'https://example.org/health'; Attempt = 2 }
PS> Write-AppLog -Level SomewhatVerbose -Message 'Retrying endpoint' -Target $ctx -Tag 1012

Example 5: SolarWinds-friendly output, preserving original level
PS> try {
>>   Throw 'Simulated failure'
>> } catch {
>>   Write-AppLog -Exception $_.Exception -Message 'Probe failed' -Level Error -EmitForSolarWinds -PreserveLevel -Tag 5100
>> }

Example 6: Seed defaults for the whole session and override per-call
PS> $script:logDefaults = @{
>>   Level = 'SomewhatVerbose'
>>   Tag   = 1000
>>   Data  = @{ app = 'AppHealth'; env = 'Prod' }
>> }
PS> Write-AppLog -Message 'Batch start'           # uses Tag 1000 and Data from defaults
PS> Write-AppLog -Message 'Specific event' -Tag 1015  # overrides Tag

.NOTES
- Requires PSFramework. Install-Module PSFramework -Scope CurrentUser (or AllUsers).
- Tag precedence: If both -Exception and -Target are supplied, exception handling takes precedence (Target is ignored unless in SolarWinds mode where a summary is written to Target).
- SolarWinds mode is designed to minimize verbosity-induced suppression while preserving the original level in Data.OriginalLevel and marking events with Data.EmitMode = 'SAM'.
- This function produces no terminating errors; it delegates to Write-PSFMessage based on configured providers.

.LINK
Write-PSFMessage
Start-AppHealthLogging
about_CommonParameters
PSFramework docs: https://github.com/PowershellFrameworkCollective/psframework
#>
function Write-AppLog {
    [CmdletBinding()]
    param(
        [Parameter()][ValidateNotNullOrEmpty()]
        [string]$Message,
        [ValidateRange(1,65535)]
        [int]$Tag,
        [Parameter()]
        [ValidateSet('Critical','Host','Output','Important','Significant','VeryVerbose','Verbose','SomewhatVerbose','System','Debug','InternalComment','Warning','Error')]
        [string]$Level = 'Verbose',
        [Parameter()][object]$Target,
        [Parameter()][System.Exception]$Exception,
        [Parameter()][string]$FunctionName,
        [switch]$PreserveLevel,
        [hashtable]$LogDefaults = $script:logDefaults,
        [switch]$EmitForSolarWinds = $script:EmitForSolarWinds
    )
    if ($null -eq $LogDefaults) { $LogDefaults = @{ Level='Verbose'; Message=''; Tag='' } }
    $splat = $LogDefaults.Clone()

    if ($PSBoundParameters.ContainsKey('Message'))      { $splat['Message'] = $Message }
    if ($PSBoundParameters.ContainsKey('Tag'))          { $splat['Tag']     = $Tag }
    if ($PSBoundParameters.ContainsKey('FunctionName')) { $splat['FunctionName'] = $FunctionName }

    $hasException = $PSBoundParameters.ContainsKey('Exception') -and ($null -ne $Exception)
    $hasTarget    = $PSBoundParameters.ContainsKey('Target')    -and ($null -ne $Target)

    $effectiveLevel = $Level

    if ($EmitForSolarWinds -and -not $PreserveLevel) {
        $data = @{}
        if ($splat.ContainsKey('Data') -and $splat['Data'] -is [hashtable]) { $data = $splat['Data'] }
        $data['OriginalLevel'] = $Level
        $data['EmitMode']      = 'SAM'
        $splat['Data'] = $data
        $effectiveLevel = 'Verbose'
    }

    if ($hasException) {
        if ($EmitForSolarWinds -and -not $PreserveLevel) {
            $ex = $Exception
            $exSummary = [pscustomobject]@{
                Message = $ex.Message
                Type    = $ex.GetType().FullName
                HResult = $ex.HResult
                Source  = $ex.Source
            }
            if ($ex.StackTrace) {
                $exSummary | Add-Member -NotePropertyName StackTop -NotePropertyValue ($ex.StackTrace.Split("`n")[0].Trim())
            }
            $splat['Target'] = $exSummary
        }
        else {
            $splat['Exception'] = $Exception
            if (-not $PSBoundParameters.ContainsKey('Level')) { $effectiveLevel = 'Error' }
        }
    }
    elseif ($hasTarget) {
        $splat['Target'] = $Target
    }

    $splat['Level'] = $effectiveLevel
    Write-PSFMessage @splat
}