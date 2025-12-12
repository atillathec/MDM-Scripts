<#
.SYNOPSIS
Deletes Microsoft Entra devices listed in a CSV (from Script 1).

.DESCRIPTION
CSV must have a column named "Id" that contains the Entra device object Id
(the GUID that Get-MgDevice returns).

Supports -WhatIf and an optional "disable-then-delete" pattern.

.REFERENCE
https://learn.microsoft.com/en-us/entra/identity/devices/manage-stale-devices
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [switch]$WhatIf,                 # dry run – show what would be deleted
    [switch]$DisableFirst,           # optional best-practice: disable first, then delete after you've waited
    [int]$SleepSeconds = 0           # pause between deletes
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV '$CsvPath' not found."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Error "Microsoft.Graph PowerShell SDK not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

# we need write permission to devices
Connect-MgGraph -Scopes "Device.ReadWrite.All"
Select-MgProfile -Name "v1.0"

$rows = Import-Csv -Path $CsvPath

Write-Host "Devices in CSV: $($rows.Count)"

foreach ($row in $rows) {
    $deviceId = $row.Id
    if (-not $deviceId) {
        Write-Warning "Row missing Id, skipping: $($row | ConvertTo-Json -Compress)"
        continue
    }

    Write-Host "Processing device $deviceId ($($row.DisplayName))..."

    if ($DisableFirst) {
        if ($WhatIf) {
            Write-Host "  [WhatIf] Would disable device $deviceId"
        } else {
            try {
                $params = @{ accountEnabled = $false }
                Update-MgDevice -DeviceId $deviceId -BodyParameter $params
                Write-Host "  Disabled."
            } catch {
                Write-Warning "  Failed to disable $deviceId : $($_.Exception.Message)"
            }
        }
    }

    if ($WhatIf) {
        Write-Host "  [WhatIf] Would delete device $deviceId"
    } else {
        try {
            Remove-MgDevice -DeviceId $deviceId
            Write-Host "  Deleted device $deviceId"
        } catch {
            Write-Warning "  Failed to delete $deviceId : $($_.Exception.Message)"
        }
    }

    if ($SleepSeconds -gt 0) {
        Start-Sleep -Seconds $SleepSeconds
    }
}

Write-Host "Done."
