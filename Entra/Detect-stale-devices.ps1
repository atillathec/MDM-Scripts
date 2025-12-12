<#
.SYNOPSIS
Exports Microsoft Entra devices that have not checked in for 6+ months to CSV.

.REFERENCE
https://learn.microsoft.com/en-us/entra/identity/devices/manage-stale-devices
#>

param(
    [int]$StaleDays = 180,                           # 6 months-ish
    [string]$OutputPath = ".\stale-devices-$((Get-Date).ToString('yyyyMMdd-HHmm')).csv",
    [switch]$IncludeDevicesWithNoTimestamp,          # some active devices can have empty timestamps, so this is opt-in :contentReference[oaicite:2]{index=2}
    [switch]$ExcludeAutopilot                        # try to avoid nuking Autopilot-linked devices :contentReference[oaicite:3]{index=3}
)

# 1. Make sure the Microsoft Graph module is available
if (-not (Get-Module -ListAvailable -Name Microsoft.Graph)) {
    Write-Error "Microsoft.Graph PowerShell SDK not found. Run: Install-Module Microsoft.Graph -Scope CurrentUser"
    exit 1
}

# 2. Connect – we need to READ devices, and (optionally) read Autopilot identities
$scopes = @("Device.Read.All")
if ($ExcludeAutopilot) {
    $scopes += "DeviceManagementServiceConfig.Read.All"
}

Connect-MgGraph -Scopes $scopes
Select-MgProfile -Name "v1.0"

# 3. Build cutoff date
$cutoff = (Get-Date).AddDays(-$StaleDays)

# 4. Pull devices with the properties we care about
$props = @(
    "id",
    "deviceId",
    "displayName",
    "accountEnabled",
    "operatingSystem",
    "operatingSystemVersion",
    "trustType",
    "approximateLastSignInDateTime"
)

$allDevices = Get-MgDevice -All -Property $props | Select-Object $props
Write-Host "Total devices retrieved: $($allDevices.Count)"

# 5. (Optional) build a lookup of Autopilot devices so we can exclude them
$autoPilotLookup = @{}
if ($ExcludeAutopilot) {
    $apDevices = Get-MgDeviceManagementWindowsAutopilotDeviceIdentity -All
    foreach ($ap in $apDevices) {
        if ($ap.azureAdDeviceId) {
            # azureAdDeviceId matches the Entra device Id (not deviceId)
            $autoPilotLookup[$ap.azureAdDeviceId] = $true
        }
    }
    Write-Host "Autopilot devices discovered: $($autoPilotLookup.Count)"
}

# 6. Filter to stale devices
$stale = foreach ($d in $allDevices) {

    # skip Autopilot, if asked
    if ($ExcludeAutopilot -and $autoPilotLookup.ContainsKey($d.Id)) {
        continue
    }

    if ($null -ne $d.ApproximateLastSignInDateTime -and $d.ApproximateLastSignInDateTime -ne "") {
        $last = [datetime]$d.ApproximateLastSignInDateTime
        if ($last -le $cutoff) {
            $d
        }
    }
    elseif ($IncludeDevicesWithNoTimestamp) {
        # MS warns some active devices have blank timestamps – so only include them if asked for :contentReference[oaicite:4]{index=4}
        $d
    }
}

Write-Host "Stale devices (>$StaleDays days): $($stale.Count)"

# 7. Export
$stale |
    Select-Object @{n='Id';e={$_.Id}},
                  @{n='DeviceId';e={$_.DeviceId}},
                  DisplayName,
                  AccountEnabled,
                  OperatingSystem,
                  OperatingSystemVersion,
                  TrustType,
                  @{n='ApproximateLastSignInDateTime';e={$_.ApproximateLastSignInDateTime}} |
    Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8

Write-Host "Exported to $OutputPath"
