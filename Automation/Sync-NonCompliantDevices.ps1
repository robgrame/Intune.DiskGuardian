<#
.SYNOPSIS
    Bidirectional sync based on Intune Proactive Remediation results.
    Adds devices with low disk space to an Entra group, removes those
    that have recovered.

.DESCRIPTION
    This script authenticates to Microsoft Graph using an App Registration
    (client credentials flow), queries the Intune Device Health Script
    (Proactive Remediation) run states to determine which devices have
    low disk space, and performs bidirectional sync with a target Entra
    ID security group.

    Designed to run as a Windows Scheduled Task or Azure Automation Runbook.

.PARAMETER TenantId
    Azure AD / Entra tenant ID.

.PARAMETER ClientId
    App Registration (client) ID.

.PARAMETER ClientSecret
    App Registration client secret. For production, retrieve this from
    Azure Key Vault or Windows Credential Manager.

.PARAMETER EntraGroupId
    Object ID of the Entra ID security group to sync devices with.

.PARAMETER HealthScriptId
    Intune Device Health Script (Proactive Remediation) ID.
    Find it via Graph: GET deviceManagement/deviceHealthScripts
    or in the Intune portal URL.

.PARAMETER ThresholdGB
    Free disk space threshold in GB. Must match the detection script.
    Default: 25.

.EXAMPLE
    .\Sync-NonCompliantDevices.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-secret-here" `
        -EntraGroupId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -HealthScriptId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Required Graph Application Permissions:
    - DeviceManagementConfiguration.Read.All
    - GroupMember.ReadWrite.All
    - Device.Read.All

    Use Register-App.ps1 to create the App Registration with these permissions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$TenantId,

    [Parameter(Mandatory)]
    [string]$ClientId,

    [Parameter(Mandatory)]
    [string]$ClientSecret,

    [Parameter(Mandatory)]
    [string]$EntraGroupId,

    [Parameter(Mandatory)]
    [string]$HealthScriptId,

    [double]$ThresholdGB = 25
)

$ErrorActionPreference = "Stop"

# ── Logging helper ───────────────────────────────────────────────────────────
function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "[$timestamp] [$Level] $Message"
}

# ── Acquire OAuth token (client credentials) ─────────────────────────────────
function Get-GraphToken {
    param([string]$TenantId, [string]$ClientId, [string]$ClientSecret)

    $body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = "https://graph.microsoft.com/.default"
    }

    $tokenResponse = Invoke-RestMethod `
        -Method Post `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
        -ContentType "application/x-www-form-urlencoded" `
        -Body $body

    return $tokenResponse.access_token
}

# ── Graph API helper with pagination ─────────────────────────────────────────
function Invoke-GraphGet {
    param([string]$Uri, [hashtable]$Headers)

    $results = @()
    $nextLink = $Uri

    while ($nextLink) {
        $response = Invoke-RestMethod -Method Get -Uri $nextLink -Headers $Headers
        if ($response.value) {
            $results += $response.value
        }
        $nextLink = $response.'@odata.nextLink'
    }

    return $results
}

# ══════════════════════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════════════════════

Write-Log "Starting bidirectional device sync..."
Write-Log "Health Script ID: $HealthScriptId"
Write-Log "Threshold: $ThresholdGB GB"
Write-Log "Target Entra group: $EntraGroupId"

# 1. Authenticate
Write-Log "Authenticating to Microsoft Graph..."
$token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
$headers = @{
    Authorization    = "Bearer $token"
    "Content-Type"   = "application/json"
    ConsistencyLevel = "eventual"
}

# 2. Query Health Script device run states (beta endpoint)
Write-Log "Querying Proactive Remediation run states..."
$runStates = Invoke-GraphGet `
    -Uri "https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/$HealthScriptId/deviceRunStates?`$expand=managedDevice(`$select=id,deviceName,azureADDeviceId)&`$select=detectionState,preRemediationDetectionScriptOutput&`$top=100" `
    -Headers $headers

Write-Log "Retrieved $($runStates.Count) device run state(s)."

# 3. Identify devices with low disk space
$lowDiskDevices = @{}  # azureADDeviceId -> deviceName

foreach ($state in $runStates) {
    $managedDevice = $state.managedDevice
    if (-not $managedDevice) { continue }

    $azureADDeviceId = $managedDevice.azureADDeviceId
    $deviceName = $managedDevice.deviceName

    if (-not $azureADDeviceId) { continue }

    $isLowDisk = ($state.detectionState -eq "fail")

    # Try to parse the script output for more accurate check
    $scriptOutput = $state.preRemediationDetectionScriptOutput
    if ($scriptOutput) {
        try {
            $parsed = $scriptOutput | ConvertFrom-Json
            if ($null -ne $parsed.FreeSpaceGB) {
                $isLowDisk = ($parsed.FreeSpaceGB -lt $ThresholdGB)
                Write-Log "  $deviceName : $($parsed.FreeSpaceGB) GB free $(if ($isLowDisk) {'→ LOW'} else {'→ OK'})"
            }
        }
        catch {
            # Fall back to detectionState
        }
    }

    if ($isLowDisk) {
        $lowDiskDevices[$azureADDeviceId] = $deviceName
    }
}

Write-Log "Found $($lowDiskDevices.Count) device(s) with low disk space."

# 4. Get current device members of the target Entra group
Write-Log "Retrieving current members of Entra group..."
$existingMembers = Invoke-GraphGet `
    -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroupId/members/microsoft.graph.device?`$select=id,deviceId,displayName&`$top=100" `
    -Headers $headers

$existingDeviceMap = @{}
foreach ($member in $existingMembers) {
    if ($member.deviceId) {
        $existingDeviceMap[$member.deviceId] = @{
            ObjectId    = $member.id
            DisplayName = $member.displayName
        }
    }
}
Write-Log "Group currently has $($existingDeviceMap.Count) device member(s)."

# ── 5. ADD low-disk devices not yet in the group ─────────────────────────────
$addedCount = 0
$addSkippedCount = 0
$addErrorCount = 0

foreach ($azureADDeviceId in $lowDiskDevices.Keys) {
    $deviceName = $lowDiskDevices[$azureADDeviceId]

    if ($existingDeviceMap.ContainsKey($azureADDeviceId)) {
        $addSkippedCount++
        continue
    }

    # Look up the Entra device object
    try {
        $entraDevices = Invoke-RestMethod `
            -Method Get `
            -Uri "https://graph.microsoft.com/v1.0/devices?`$filter=deviceId eq '$azureADDeviceId'&`$select=id,displayName,deviceId" `
            -Headers $headers

        if (-not $entraDevices.value -or $entraDevices.value.Count -eq 0) {
            Write-Log "Device '$deviceName' ($azureADDeviceId) not found in Entra ID — skipping." "WARN"
            $addSkippedCount++
            continue
        }

        $entraDeviceObjectId = $entraDevices.value[0].id
    }
    catch {
        Write-Log "Failed to look up Entra device for '$deviceName': $($_.Exception.Message)" "ERROR"
        $addErrorCount++
        continue
    }

    try {
        $addBody = @{
            "@odata.id" = "https://graph.microsoft.com/v1.0/directoryObjects/$entraDeviceObjectId"
        } | ConvertTo-Json

        Invoke-RestMethod `
            -Method Post `
            -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroupId/members/`$ref" `
            -Headers $headers `
            -Body $addBody | Out-Null

        Write-Log "Added '$deviceName' ($azureADDeviceId) to group."
        $addedCount++
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 400) {
            Write-Log "Device '$deviceName' already a member (race condition) — skipping." "WARN"
            $addSkippedCount++
        }
        else {
            Write-Log "Failed to add '$deviceName' to group: $($_.Exception.Message)" "ERROR"
            $addErrorCount++
        }
    }
}

# ── 6. REMOVE devices from group that no longer have low disk space ──────────
$removedCount = 0
$removeSkippedCount = 0
$removeErrorCount = 0

foreach ($deviceId in $existingDeviceMap.Keys) {
    if ($lowDiskDevices.ContainsKey($deviceId)) {
        $removeSkippedCount++
        continue
    }

    $info = $existingDeviceMap[$deviceId]
    $objectId = $info.ObjectId
    $displayName = $info.DisplayName

    try {
        Invoke-RestMethod `
            -Method Delete `
            -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroupId/members/$objectId/`$ref" `
            -Headers $headers | Out-Null

        Write-Log "Removed '$displayName' ($deviceId) from group — disk space OK."
        $removedCount++
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Log "Device '$displayName' ($deviceId) already removed (race condition)." "WARN"
            $removeSkippedCount++
        }
        else {
            Write-Log "Failed to remove '$displayName' ($deviceId): $($_.Exception.Message)" "ERROR"
            $removeErrorCount++
        }
    }
}

# ── 7. Summary ───────────────────────────────────────────────────────────────
Write-Log "──────────────────────────────────"
Write-Log "Bidirectional sync complete."
Write-Log "  Added   : $addedCount"
Write-Log "  Removed : $removedCount"
Write-Log "  Skipped : $($addSkippedCount + $removeSkippedCount) (add: $addSkippedCount, remove: $removeSkippedCount)"
Write-Log "  Errors  : $($addErrorCount + $removeErrorCount) (add: $addErrorCount, remove: $removeErrorCount)"
Write-Log "──────────────────────────────────"
