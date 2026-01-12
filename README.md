# DDNS Registration Client

A PowerShell 7+ script to update dynamic DNS (DDNS) records for IPv4 and IPv6
addresses. It currently supports updating
[Cloudflare DNS](https://developers.cloudflare.com/api/operations/dns-records-for-a-zone-patch-dns-record)
records in [Cloudflare](https://www.cloudflare.com/products/registrar/).

## Usage

Create a config file at `~/.ddns/config.json` and add your records to it. See
[./config.json](./config.json) for an example.

```powershell
# Copy the example config file to the user's home directory if it doesn't already exist
if (!(Test-Path -Path '~/.ddns/config.json')) {
    $null = New-Item '~/.ddns' -ItemType Directory -Force
    Copy-Item './config.json' '~/.ddns/config.json'
    # e.g., code (Convert-Path '~/.ddns/config.json')
}
```

Run the script to update the configured DDNS records:

```powershell
./update-ddns.ps1
```

The script will log its actions to `~/.ddns/update.log` and maintain a status
file at `~/.ddns/status.json`. Both of these paths can be customized in the
config file.

## Run on a schedule

Use the following PowerShell script to create a Windows Scheduled Task which
starts at logon of the current user and then runs daily at 8AM:

```powershell
cd C:\dev\ddns # path to where update-ddns.ps1 is located

New-ScheduledTask `
    -Action (New-ScheduledTaskAction `
        -Execute (Get-Command pwsh).Path `
        -Argument '-nologo -nop -ep bypass -w hidden -f update-ddns.ps1' `
        -WorkingDirectory $PWD) `
    -Trigger `
        (New-ScheduledTaskTrigger -AtLogOn),
        (New-ScheduledTaskTrigger -Daily -At (Get-Date '08:00')) | `
Register-ScheduledTask -TaskName 'Update DDNS' -Force

# Execute now:
Start-ScheduledTask -TaskName 'Update DDNS'

# Delete:
# Unregister-ScheduledTask -TaskName 'Update DDNS'
```
