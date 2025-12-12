<#
.SYNOPSIS
For every device in a CSV (with columns Id, DeviceId, DisplayName),
pull BitLocker recovery keys from Entra and write a FLAT, readable CSV.

CSV schema out:
EntraObjectId,DeviceId,DisplayName,BitLockerKeyId,RecoveryKey,VolumeType,KeyCreated
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    [string]$OutputPath = ".\stale-devices-bitlocker-backup-$((Get-Date).ToString('yyyyMMdd-HHmm')).csv",
    [switch]$SkipDevicesWithoutDeviceId,
    [int]$DelayMs = 250
)

if (-not (Test-Path $CsvPath)) {
    Write-Error "CSV '$CsvPath' not found."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Error "Microsoft.Graph PowerShell SDK not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

$devices = Import-Csv -Path $CsvPath
Write-Host "Devices loaded: $($devices.Count)"

# Need to be able to read bitlocker keys
Connect-MgGraph -Scopes "BitlockerKey.Read.All","Device.Read.All"
Select-MgProfile -Name "v1.0"

$rowsOut = @()

foreach ($dev in $devices) {
    $aadObjectId = $dev.Id
    $deviceId    = $dev.DeviceId
    $name        = $dev.DisplayName

    if ([string]::IsNullOrWhiteSpace($deviceId)) {
        if ($SkipDevicesWithoutDeviceId) {
            Write-Warning "[$name] has no DeviceId – skipping."
            continue
        } else {
            Write-Warning "[$name] has no DeviceId – adding placeholder row."
            $rowsOut += [pscustomobject]@{
                EntraObjectId  = $aadObjectId
                DeviceId       = $null
                DisplayName    = $name
                BitLockerKeyId = $null
                RecoveryKey    = $null
                VolumeType     = $null
                KeyCreated     = $null
            }
            continue
        }
    }

    Write-Host "Looking up keys for deviceId $deviceId ($name)..."

    # 1) list keys for this device
    $list = Get-MgInformationProtectionBitlockerRecoveryKey -All -Filter "deviceId eq '$deviceId'"

    if (-not $list -or $list.Count -eq 0) {
        # nothing found, log it
        $rowsOut += [pscustomobject]@{
            EntraObjectId  = $aadObjectId
            DeviceId       = $deviceId
            DisplayName    = $name
            BitLockerKeyId = $null
            RecoveryKey    = $null
            VolumeType     = $null
            KeyCreated     = $null
        }
        continue
    }

    foreach ($k in $list) {
        # many Graph builds put the actual props into AdditionalProperties
        $ap = $k.AdditionalProperties

        $keyId     = $k.Id
        $volume    = $k.VolumeType
        $created   = $k.CreatedDateTime

        if (-not $volume -and $ap.ContainsKey("volumeType")) {
            $volume = $ap["volumeType"]
        }
        if (-not $created -and $ap.ContainsKey("createdDateTime")) {
            $created = $ap["createdDateTime"]
        }

        # 2) now fetch the actual recovery key (this is what was unreadable before)
        $recoveryKeyValue = $null
        try {
            $full = Get-MgInformationProtectionBitlockerRecoveryKey -BitlockerRecoveryKeyId $keyId -Property "key"
            # depending on version, it's either .Key or .AdditionalProperties["key"]
            if ($full.Key) {
                $recoveryKeyValue = $full.Key
            } elseif ($full.AdditionalProperties -and $full.AdditionalProperties.ContainsKey("key")) {
                $recoveryKeyValue = $full.AdditionalProperties["key"]
            }
        } catch {
            Write-Warning "Failed to read key value for $keyId on $name: $($_.Exception.Message)"
        }

        $rowsOut += [pscustomobject]@{
            EntraObjectId  = $aadObjectId
            DeviceId       = $deviceId
            DisplayName    = $name
            BitLockerKeyId = $keyId
            RecoveryKey    = $recoveryKeyValue
            VolumeType     = $volume
            KeyCreated     = $created
        }

        if ($DelayMs -gt 0) {
            Start-Sleep -Milliseconds $DelayMs
        }
    }
}

$rowsOut | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8
Write-Host "BitLocker backup written to: $OutputPath"
