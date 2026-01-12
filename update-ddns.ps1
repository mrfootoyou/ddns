<#
.SYNOPSIS
    Dynamic DNS updater script.
.DESCRIPTION
    This script updates DNS records for dynamic IP addresses using
    various DNS registrars' APIs. It fetches the current public IPv4
    and IPv6 addresses and updates the registrars' DNS records accordingly.

    It currently supports Cloudflare as a DNS registrar.

    All configuration is done via a JSON config file.
#>
#requires -Version 7
[CmdletBinding()]
param(
    # Path to the configuration file. Defaults to "~/.ddns/config.json"
    [string] $ConfigPath = '~/.ddns/config.json'
)

# Validation and loading of config file

$ConfigPath = $PSCmdlet.GetUnresolvedProviderPathFromPSPath($ConfigPath)
if (!(Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
    Write-Error -Exception "ConfigFile not found: '$ConfigPath'."
    return
}
try {
    $config = Get-Content $ConfigPath | ConvertFrom-Json -Depth 64
}
catch {
    Write-Error -Exception "Failed to parse '$ConfigPath': $($_.Exception.Message)"
    return
}
$configDir = Split-Path $ConfigPath -Parent
$logPath = [System.IO.Path]::Combine($configDir, $config.logPath ?? 'update.log')
$statusPath = [System.IO.Path]::Combine($configDir, $config.statusPath ?? 'status.json')

function log {
    <#
    .DESCRIPTION
        Logs a message to the console and log file.
    #>
    param(
        # The message to log.
        [Parameter(Mandatory)]
        [string] $Message,
        # The log level.
        [ValidateSet('Debug', 'Info', 'Warn', 'Error')]
        [string] $Level = 'Info',
        # Exclude the timestamp and level prefix.
        [switch] $NoPrefix,
        # The exception associated with the log.
        [System.Exception] $Exception,
        # The error record associated with the log.
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )
    try {
        $lvl, $color = switch ($Level) {
            'Info' { 'INF', $PSStyle.Foreground.White }
            'Warn' { 'WRN', $PSStyle.Foreground.Yellow }
            'Error' { 'ERR', $PSStyle.Foreground.Red }
            'Debug' { 'DBG', $PSStyle.Foreground.BrightBlack }
        }
        $hostMsg = $Message
        $logMsg = $Message
        if (!$Exception -and $ErrorRecord) {
            $Exception = $ErrorRecord.Exception
        }
        if ($Exception) {
            # ignore the exception stack trace since it is (almost) always useless
            $ex = "`n" + $Exception.GetType().FullName + ': ' + $Exception.Message
            $logMsg += $ex
            $hostMsg += $ex
        }
        if ($ErrorRecord) {
            $ex = "`n" + $ErrorRecord.ScriptStackTrace
            $logMsg += $ex
            $hostMsg += $PSStyle.Dim + $PSStyle.Italic + $ex + $PSStyle.ItalicOff + $PSStyle.DimOff
        }
        if (!$NoPrefix) {
            $ts = Get-Date -Format o
            $logMsg = "[$ts $lvl] $logMsg"
            $hostPrefix = $PSStyle.Dim + $PSStyle.Foreground.White + '['
            $hostPrefix += $ts + ' ' + $color + $lvl
            $hostPrefix += $PSStyle.Foreground.White + '] ' + $PSStyle.DimOff
            $hostMsg = $hostPrefix + $hostMsg
        }
        Write-Host $hostMsg
        if ($logPath) {
            writeLogFile $logMsg
        }
    }
    catch {
        # Do not throw from logging
        # Set $DebugPreference to 'Continue' to see these messages
        $_ | Out-String | Write-Debug
    }
}
function logInfo {
    param(
        # The message to log.
        [Parameter(Mandatory)]
        [string] $Message,
        # Exclude the timestamp and level prefix.
        [switch] $NoPrefix
    )
    log @PSBoundParameters -Level Info
}
function logError {
    param(
        # The message to log.
        [Parameter(Mandatory)]
        [string] $Message,
        # The exception associated with the log.
        [System.Exception] $Exception,
        # The error record associated with the log.
        [System.Management.Automation.ErrorRecord] $ErrorRecord
    )
    log @PSBoundParameters -Level Error
}
function logWarn {
    param(
        # The message to log.
        [Parameter(Mandatory)]
        [string] $Message
    )
    log @PSBoundParameters -Level Warn
}

function writeLogFile([string] $Message) {
    $logPath ??= throw "Log path is not set."

    rotateLogFileIfNeeded `
        -LogPath $logPath `
        -FileMaxSize (($config.logFileMaxSizeKB ?? 100) * 1KB) `
        -KeepLast ($config.logFileKeepLast ?? 4)

    $Message | Out-File -FilePath $logPath -Append -Force -ea SilentlyContinue
}

function rotateLogFileIfNeeded {
    param(
        [Parameter(Mandatory)]
        [string] $LogPath,
        [ValidateRange(1KB, [long]::MaxValue)]
        [long] $FileMaxSize = 100KB,
        [ValidateRange(-1, [int]::MaxValue)]
        [int] $KeepLast = 4,
        [switch] $CreateEmpty
    )

    if (!(Test-Path -LiteralPath $LogPath)) { return }

    $log = Get-Item $LogPath -ea Stop
    $LogPath = $log.FullName
    if ($log.Length -lt $FileMaxSize) { return }

    # Note: Cannot use file's CreationTime because Windows uses the renamed file's creation time for the new log file!!!
    $newLogExt = [datetime]::Now.ToString('yyyyMMdd\THHmmss') + '.log'
    $newLogName = [System.IO.Path]::ChangeExtension($LogPath, $newLogExt)
    Write-Verbose "Rotating log file to '$newLogName'."
    if (!(Rename-Item -Path $LogPath -NewName $newLogName -Force -PassThru)) {
        # failed to rename log file
        return
    }

    if ($KeepLast -ge 0) {
        # delete old log files
        $oldLogFiles = @(
            Get-ChildItem ([System.IO.Path]::ChangeExtension($LogPath, ".*.log")) |
            Where-Object Name -Match '\.\d{8}T\d{6}\.log$' |
            Sort-Object Name -Descending |
            Select-Object -Skip $KeepLast
        )
        if ($oldLogFiles.Count -gt 0) {
            Write-Verbose "Deleting $($oldLogFiles.Count) old log file(s)."
            $oldLogFiles | Remove-Item -Force -ea Continue
        }
    }

    if ($CreateEmpty) {
        [System.IO.File]::OpenWrite($LogPath).Close()
    }
}

function updateCloudFlareDNS {
    <#
    .DESCRIPTION
        Updates a Cloudflare DNS record with the provided IP addresses.
    #>
    param(
        [Parameter(Mandatory)]
        [object] $Record,
        [IpAddress] $IpAddress,
        [System.Collections.IDictionary] $RecordStatus
    )

    if (!$Record.apiToken) {
        $RecordStatus.result = 'error'
        $RecordStatus.error = "API token not provided. Specify 'apiToken' in the config record."
        return
    }

    $baseUrl = 'https://api.cloudflare.com/client/v4'
    $headers = @{ Authorization = "Bearer $($Record.apiToken)" }
    $resp = Invoke-RestMethod -Method GET -Uri "$baseUrl/zones" -Headers $headers
    $zone = $resp.result.where{ $_.name -eq $Record.zoneName }
    if (@($zone).Count -ne 1) {
        $RecordStatus.result = 'error'
        $RecordStatus.error = "DNS zone '$($Record.zoneName)' not found."
        return
    }

    $resp = Invoke-RestMethod -Method GET -Uri "$baseUrl/zones/$($zone.id)/dns_records" -Headers $headers
    $dnsRecords = $resp.result.where{ $_.name -eq $Record.recordName }
    if (@($dnsRecords).Count -eq 0) {
        $RecordStatus.result = 'error'
        $RecordStatus.error = "DNS record '$($Record.recordName)' not found."
        return
    }

    $RecordStatus.lastUpdate = [ordered]@{
        time = $RecordStatus.timestamp
    }

    foreach ($dnsRecord in $dnsRecords) {
        $patch = $null
        if ($dnsRecord.type -eq 'A') {
            $RecordStatus.lastUpdate.ip4 = $IpAddress.IP4
            if ($dnsRecord.content -ne $IpAddress.IP4) {
                $patch = @{ content = $IpAddress.IP4 }
            }
            else {
                logInfo "IP4 unchanged ($($dnsRecord.content))."
            }
        }
        elseif ($IpAddress.IP6 -and $dnsRecord.type -eq 'AAAA') {
            $RecordStatus.lastUpdate.ip6 = $IpAddress.IP6
            if ($dnsRecord.content -ne $IpAddress.IP6) {
                $patch = @{ content = $IpAddress.IP6 }
            }
            else {
                logInfo "IP6 unchanged ($($dnsRecord.content))."
            }
        }
        if ($patch) {
            logInfo "Updating $($dnsRecord.name) $($dnsRecord.type) record with address $($patch.content)."
            $resp = Invoke-RestMethod -Method PATCH -Uri "$baseUrl/zones/$($zone.id)/dns_records/$($dnsRecord.id)" -Body ($patch | ConvertTo-Json) -Headers $headers
            $dnsRecord = $resp.result
            logInfo "Success! Recorded address: $($dnsRecord.content)."
        }
    }
    $RecordStatus.result = 'success'
}

class IpAddress {
    [string] $IP4
    [string] $IP6

    IpAddress([string] $ip4, [string] $ip6) {
        $this.IP4 = $ip4
        $this.IP6 = $ip6
    }
}

function getIpAddress {
    <#
    .DESCRIPTION
        Fetches the current public IPv4 and IPv6 addresses.
    .OUTPUTS
        An IpAddress object.
    #>
    [OutputType([IpAddress])]
    param()
    if (!($curl = Get-Command 'curl' -Type Application -ea Ignore | Select-Object -First 1)) {
        throw "curl not found. Please install curl and ensure it is in the system PATH."
    }

    logInfo 'Fetching IPv4 from https://api.ipify.org...'
    $ip4 = & $curl 'https://api.ipify.org' --connect-timeout 5 --retry 5 --retry-delay 10 --silent
    if ($LASTEXITCODE -ne 0 -or !$ip4) {
        throw "Failed to fetch IPv4 address."
    }
    logInfo "IPv4: $ip4"

    logInfo 'Fetching IPv6 from https://api6.ipify.org...'
    $ip6 = & $curl 'https://api6.ipify.org' --connect-timeout 5 --retry 5 --retry-delay 10 --silent
    if ($LASTEXITCODE -ne 0 -or !$ip6) {
        logWarn "Failed to fetch IPv6 address."
    }
    else {
        logInfo "IPv6: $ip6"
    }

    return [IpAddress]::new($ip4, $ip6)
}

# Main script logic

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

trap {
    logError "Unhandled exception:" -ErrorRecord $_
    exit 2
}

logInfo "=== Starting DDNS update script ==="
$startTime = Get-Date

$status = [ordered]@{}
if (Test-Path $statusPath) {
    $status = Get-Content $statusPath | ConvertFrom-Json -AsHashtable -Depth 64
}

$ipAddress = getIpAddress
$errorCount = 0
foreach ($record in @($config.records ?? @())) {
    logInfo "Updating $($record.registrar) DNS record for $($record.recordName)..."

    $recordStatus = [ordered]@{
        timestamp  = [System.DateTimeOffset]::Now
        result     = $null
        lastUpdate = $status[$record.recordName].lastUpdate
    }

    try {
        switch ($record.registrar) {
            "Cloudflare" {
                $null = updateCloudFlareDNS -Record $record -IpAddress $ipAddress -RecordStatus $recordStatus
            }
            Default {
                throw "Unknown registrar: $($record.registrar)."
            }
        }
    }
    catch {
        $recordStatus.result = 'failure'
        $recordStatus.error = $_.Exception.Message
        logError "Failed to update DNS record for $($record.recordName):" -ErrorRecord $_
    }

    # Update status file
    if ($recordStatus.result -in 'error', 'failure') {
        $errorCount++
    }
    $status[$record.recordName] = $recordStatus
    $status | ConvertTo-Json -Depth 64 | Out-File -FilePath $statusPath -Force
}

$duration = (Get-Date) - $startTime
log "Completed in $duration with $errorCount error(s)." -Level ($errorCount -gt 0 ? 'Error' : 'Info')
exit ($errorCount -gt 0 ? 1 : 0)
