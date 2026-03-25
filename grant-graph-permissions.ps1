<#
.SYNOPSIS
    Grants Microsoft Graph API permissions to the Logic App's Managed Identity.

.DESCRIPTION
    After deploying the Logic App, run this script to assign the required
    Microsoft Graph application permissions to the system-assigned Managed Identity.
    
    Required permissions:
    - DeviceManagementManagedDevices.Read.All (read Intune device inventory)
    - GroupMember.ReadWrite.All (add members to Entra group)
    - Device.Read.All (look up Entra device objects)

.PARAMETER ManagedIdentityObjectId
    The Object ID of the Logic App's system-assigned Managed Identity.
    Get it from the deployment output or the Azure Portal.

.EXAMPLE
    .\grant-graph-permissions.ps1 -ManagedIdentityObjectId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ManagedIdentityObjectId
)

# Microsoft Graph Service Principal App ID (constant across all tenants)
$graphAppId = "00000003-0000-0000-c000-000000000000"

# Required permission names (App Role IDs are resolved dynamically per-tenant)
$requiredPermissions = @(
    "DeviceManagementManagedDevices.Read.All",
    "GroupMember.Read.All",
    "GroupMember.ReadWrite.All",
    "Device.Read.All"
)

Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

# Get the Microsoft Graph Service Principal
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

if (-not $graphSp) {
    Write-Error "Could not find Microsoft Graph service principal. Ensure you are connected to the correct tenant."
    exit 1
}

# Build a lookup table: permission name -> appRoleId from the tenant's Graph SP
$appRoleLookup = @{}
foreach ($role in $graphSp.AppRoles) {
    $appRoleLookup[$role.Value] = $role.Id
}

Write-Host "`nAssigning permissions to Managed Identity: $ManagedIdentityObjectId" -ForegroundColor Cyan
Write-Host "Graph Service Principal ID: $($graphSp.Id)`n" -ForegroundColor Gray

foreach ($permName in $requiredPermissions) {
    $permId = $appRoleLookup[$permName]

    if (-not $permId) {
        Write-Host "  $permName ... " -NoNewline
        Write-Host "NOT FOUND in tenant" -ForegroundColor Red
        Write-Warning "  The permission '$permName' was not found on the Microsoft Graph service principal in this tenant."
        continue
    }

    Write-Host "  Assigning: $permName ($permId)..." -NoNewline

    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $ManagedIdentityObjectId `
            -PrincipalId $ManagedIdentityObjectId `
            -ResourceId $graphSp.Id `
            -AppRoleId $permId `
            -ErrorAction Stop | Out-Null

        Write-Host " OK" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Host " ALREADY ASSIGNED" -ForegroundColor Yellow
        }
        else {
            Write-Host " FAILED" -ForegroundColor Red
            Write-Warning "  Error: $($_.Exception.Message)"
        }
    }
}

Write-Host "`nDone! The Logic App can now access Microsoft Graph." -ForegroundColor Green
Write-Host "Note: It may take a few minutes for permissions to propagate.`n"
