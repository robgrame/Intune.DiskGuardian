<#
.SYNOPSIS
    Bidirectional sync: adds non-compliant devices to an Entra group
    and removes devices that have become compliant.

.DESCRIPTION
    This script authenticates to Microsoft Graph using an App Registration
    (client credentials flow), queries the Intune compliance state, and
    performs a bidirectional sync with a target Entra ID security group:
    - Devices flagged as non-compliant are ADDED to the group
    - Devices that are no longer non-compliant are REMOVED from the group

    Designed to run as a Windows Scheduled Task or Azure Automation Runbook.

.PARAMETER TenantId
    Azure AD / Entra tenant ID.

.PARAMETER ClientId
    App Registration (client) ID.

.PARAMETER ClientSecret
    App Registration client secret. For production, retrieve this from
    Azure Key Vault or Windows Credential Manager instead of passing as
    a plain-text parameter.

.PARAMETER EntraGroupId
    Object ID of the Entra ID security group to sync non-compliant devices with.

.EXAMPLE
    # Interactive (for testing)
    .\Sync-NonCompliantDevices.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientSecret "your-secret-here" `
        -EntraGroupId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    # Scheduled Task (retrieve secret from environment variable)
    .\Sync-NonCompliantDevices.ps1 `
        -TenantId $env:TENANT_ID `
        -ClientId $env:CLIENT_ID `
        -ClientSecret $env:CLIENT_SECRET `
        -EntraGroupId $env:ENTRA_GROUP_ID

.NOTES
    Required Graph Application Permissions:
    - DeviceManagementManagedDevices.Read.All
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
    [string]$EntraGroupId
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
Write-Log "Target Entra group: $EntraGroupId"

# 1. Authenticate
Write-Log "Authenticating to Microsoft Graph..."
$token = Get-GraphToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
$headers = @{
    Authorization  = "Bearer $token"
    "Content-Type" = "application/json"
    ConsistencyLevel = "eventual"
}

# 2. Get all non-compliant managed devices from Intune
Write-Log "Querying Intune for non-compliant devices..."
$nonCompliantDevices = Invoke-GraphGet `
    -Uri "https://graph.microsoft.com/v1.0/deviceManagement/managedDevices?`$filter=complianceState eq 'noncompliant'&`$select=id,deviceName,azureADDeviceId,complianceState,freeStorageSpaceInBytes" `
    -Headers $headers

Write-Log "Found $($nonCompliantDevices.Count) non-compliant device(s) in Intune."

# Build a lookup set of non-compliant azureADDeviceIds
$nonCompliantDeviceIds = @{}
foreach ($device in $nonCompliantDevices) {
    if ($device.azureADDeviceId) {
        $nonCompliantDeviceIds[$device.azureADDeviceId] = $true
    }
}

# 3. Get current device members of the target Entra group
Write-Log "Retrieving current members of Entra group..."
$existingMembers = Invoke-GraphGet `
    -Uri "https://graph.microsoft.com/v1.0/groups/$EntraGroupId/members/microsoft.graph.device?`$select=id,deviceId,displayName" `
    -Headers $headers

# Map: deviceId -> { objectId, displayName }
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

# ── 4. ADD non-compliant devices not yet in the group ────────────────────────
$addedCount = 0
$addSkippedCount = 0
$addErrorCount = 0

foreach ($device in $nonCompliantDevices) {
    $deviceName = $device.deviceName
    $azureADDeviceId = $device.azureADDeviceId

    if (-not $azureADDeviceId) {
        Write-Log "Device '$deviceName' has no azureADDeviceId — skipping." "WARN"
        $addSkippedCount++
        continue
    }

    if ($existingDeviceMap.ContainsKey($azureADDeviceId)) {
        Write-Log "Device '$deviceName' ($azureADDeviceId) already in group — skipping add."
        $addSkippedCount++
        continue
    }

    # Look up the Entra device object by deviceId
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

    # Add the device to the group
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

# ── 5. REMOVE devices from group that are now compliant ──────────────────────
$removedCount = 0
$removeSkippedCount = 0
$removeErrorCount = 0

foreach ($deviceId in $existingDeviceMap.Keys) {
    if ($nonCompliantDeviceIds.ContainsKey($deviceId)) {
        # Still non-compliant — keep in group
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

        Write-Log "Removed '$displayName' ($deviceId) from group — now compliant."
        $removedCount++
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 404) {
            Write-Log "Device '$displayName' ($deviceId) already removed (race condition)." "WARN"
            $removeSkippedCount++
        }
        else {
            Write-Log "Failed to remove '$displayName' ($deviceId) from group: $($_.Exception.Message)" "ERROR"
            $removeErrorCount++
        }
    }
}

# ── 6. Summary ───────────────────────────────────────────────────────────────
Write-Log "──────────────────────────────────"
Write-Log "Bidirectional sync complete."
Write-Log "  Added   : $addedCount"
Write-Log "  Removed : $removedCount"
Write-Log "  Skipped : $($addSkippedCount + $removeSkippedCount) (add: $addSkippedCount, remove: $removeSkippedCount)"
Write-Log "  Errors  : $($addErrorCount + $removeErrorCount) (add: $addErrorCount, remove: $removeErrorCount)"
Write-Log "──────────────────────────────────"
