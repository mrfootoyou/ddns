#requires -Version 7
[CmdletBinding()]
param(
    [string] $ConfigPath = "~/.ddns/config.json"
)

# Scheduled task command:
# pwsh -WindowStyle Hidden -ExecutionPolicy ByPass -NoProfile -NoLogo -Noninteractive -Command "C:\dev\ddns\update-ddns.ps1"

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSNativeCommandUseErrorActionPreference = $false

$ConfigPath = Convert-Path -LiteralPath $ConfigPath
$configDir = Split-Path $ConfigPath -Parent
$config = Get-Content $ConfigPath -ea Stop | ConvertFrom-Json -ea Stop
$config | Add-Member logPath (Join-Path $configDir "output.log") -ea ignore
$config | Add-Member statusPath (Join-Path $configDir "status.json") -ea ignore

function trace {
    param(
        [Parameter(Mandatory)]
        [string] $Message
    )
    $ts = "[$([System.DateTimeOffset]::Now.ToString('o'))] "
    Write-Host $ts -NoNewline -ForegroundColor Gray
    Write-Host $message
    "$ts$message" | Out-File -FilePath $config.logpath -Append -ea Ignore
}

$status = [ordered]@{}
if (Test-Path $config.statusPath) {
    try {
        $status = Get-Content $config.statusPath -ea Stop | ConvertFrom-Json -AsHashtable -Depth 64 -ea Stop
    }
    catch {
        trace "Error loading $($config.statusPath). Ignoring."
    }
}

trace 'Fetching IPv4 from https://api.ipify.org...'
$ip4 = curl 'https://api.ipify.org' --connect-timeout 5 --retry 5 --retry-delay 10 --silent
if ($LASTEXITCODE -ne 0 -or -not $ip4) {
    throw "Failed to fetch IPv4 address."
}
trace "IPv4: $ip4"

trace 'Fetching IPv6 from https://api6.ipify.org...'
$ip6 = curl 'https://api6.ipify.org' --connect-timeout 5 --retry 5 --retry-delay 10 --silent
if ($LASTEXITCODE -ne 0 -or -not $ip6) {
    Write-Warning "Failed to fetch IPv6 address."
}
else {
    trace "IPv6: $ip6"
}

foreach ($record in $config.records) {
    try {
        trace "Updating $($record.registrar) DNS record for $($record.recordName)..."

        $recordstatus = [ordered]@{
            timestamp  = [System.DateTimeOffset]::Now
            result     = $null
            lastUpdate = $status[$record.recordName].lastUpdate
        }

        switch ($record.registrar) {
            "Cloudflare" {                
                try {                    
                    $baseUrl = 'https://api.cloudflare.com/client/v4'
                    $headers = @{ Authorization = "Bearer $($record.apiToken)" }

                    $resp = Invoke-RestMethod -Method GET -Uri "$baseUrl/zones" -Headers $headers
                    $zone = $resp.result.where{ $_.name -eq $record.zoneName }
                    if (@($zone).Count -ne 1) {
                        Write-Error "DNS zone '$($record.zoneName)' not found."
                        break
                    }

                    $resp = Invoke-RestMethod -Method GET -Uri "$baseUrl/zones/$($zone.id)/dns_records" -Headers $headers
                    $dnsRecords = $resp.result.where{ $_.name -eq $record.recordName }
                    if (@($dnsRecords).Count -eq 0) {
                        Write-Error "DNS record '$($record.recordName)' not found."
                        break
                    }

                    $recordstatus.lastUpdate = [ordered]@{
                        time = $recordstatus.timestamp
                    }

                    foreach ($dnsRecord in $dnsRecords) {
                        $patch = $null
                        if ($dnsRecord.type -eq 'A') {
                            $recordstatus.lastUpdate.ip4 = $ip4
                            if ($dnsRecord.content -ne $ip4) {
                                $patch = @{ content = $ip4 }
                            }
                            else {
                                trace "IP4 unchanged ($($dnsRecord.content))."
                            }
                        }
                        elseif ($ip6 -and $dnsRecord.type -eq 'AAAA') {
                            $recordstatus.lastUpdate.ip6 = $ip6
                            if ($dnsRecord.content -ne $ip6) {
                                $patch = @{ content = $ip6 }
                            }
                            else {
                                trace "IP6 unchanged ($($dnsRecord.content))."
                            }
                        }
                        if ($patch) {
                            $resp = Invoke-RestMethod -Method PATCH -Uri "$baseUrl/zones/$($zone.id)/dns_records/$($dnsRecord.id)" -Body ($patch | ConvertTo-Json) -Headers $headers
                            $dnsRecord = $resp.result
                            trace "Success: Updated $($dnsRecord.name) $($dnsRecord.type) record with address $($dnsRecord.content)."
                        }
                    }
                    $recordstatus.result = 'success'
                }
                catch {
                    trace "Error: $($_.Exception.Message)"
                    $recordstatus.result = 'error'
                    $recordstatus.error = $_.Exception.Message
                }
            }
            Default {
                Write-Error "Unknown registrar: $($record.registrar)."
            }
        }

        # Update status file
        $status[$record.recordName] = $recordstatus
        $status | ConvertTo-Json | Out-File -FilePath $config.statusPath
    }
    catch {
        $ex = $_ | Select-Object -ExpandProperty Exception | Out-String
        $ex += $_ | Select-Object -ExcludeProperty Exception | Out-String
        trace "Unexpected exception: $ex"
    }
}