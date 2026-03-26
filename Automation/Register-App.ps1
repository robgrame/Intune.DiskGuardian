<#
.SYNOPSIS
    Creates an Entra ID App Registration with the permissions needed by the
    Sync-NonCompliantDevices automation.

.DESCRIPTION
    This script:
    1. Creates an App Registration in Entra ID.
    2. Assigns the required Microsoft Graph application permissions.
    3. Creates a client secret (valid for 1 year) for the automation to authenticate.
    4. Grants admin consent for the assigned permissions.

    After running this script, store the output values (TenantId, ClientId,
    ClientSecret) securely — for example in Azure Key Vault or Windows
    Credential Manager.

.PARAMETER AppDisplayName
    Display name for the App Registration (default: "Intune-DiskSpace-Sync").

.EXAMPLE
    .\Register-App.ps1
    .\Register-App.ps1 -AppDisplayName "MyCustomAppName"

.NOTES
    Requires: Microsoft.Graph PowerShell SDK
    Permissions: The signed-in user must be a Global Administrator or
    Application Administrator to create the app and grant admin consent.
#>

param(
    [string]$AppDisplayName = "IntuneDiskGuardian"
)

$ErrorActionPreference = "Stop"

# Required Microsoft Graph application permissions
$requiredPermissions = @(
    "DeviceManagementConfiguration.Read.All",    # Read health script / remediation run states
    "GroupMember.ReadWrite.All",                  # Add/remove devices in the Entra group
    "Device.Read.All"                            # Look up device objects in Entra
)

Write-Host "`n=== IntuneDiskGuardian — App Registration ===" -ForegroundColor Cyan
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Gray

Connect-MgGraph -Scopes @(
    "Application.ReadWrite.All",
    "AppRoleAssignment.ReadWrite.All"
)

# ── 1. Create the App Registration ──────────────────────────────────────────
Write-Host "`n[1/4] Creating App Registration: '$AppDisplayName'..." -ForegroundColor Yellow

$app = New-MgApplication -DisplayName $AppDisplayName -SignInAudience "AzureADMyOrg"
$sp  = New-MgServicePrincipal -AppId $app.AppId

Write-Host "  App (client) ID : $($app.AppId)" -ForegroundColor Green
Write-Host "  Object ID       : $($app.Id)"
Write-Host "  SP Object ID    : $($sp.Id)"

# ── 2. Assign Graph application permissions ──────────────────────────────────
Write-Host "`n[2/4] Assigning Microsoft Graph permissions..." -ForegroundColor Yellow

$graphAppId = "00000003-0000-0000-c000-000000000000"
$graphSp = Get-MgServicePrincipal -Filter "appId eq '$graphAppId'"

if (-not $graphSp) {
    Write-Error "Microsoft Graph service principal not found in this tenant."
    exit 1
}

$appRoleLookup = @{}
foreach ($role in $graphSp.AppRoles) {
    $appRoleLookup[$role.Value] = $role.Id
}

foreach ($permName in $requiredPermissions) {
    $roleId = $appRoleLookup[$permName]
    if (-not $roleId) {
        Write-Warning "  Permission '$permName' not found in tenant — skipping."
        continue
    }

    Write-Host "  $permName ... " -NoNewline
    try {
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $sp.Id `
            -PrincipalId $sp.Id `
            -ResourceId $graphSp.Id `
            -AppRoleId $roleId `
            -ErrorAction Stop | Out-Null
        Write-Host "OK" -ForegroundColor Green
    }
    catch {
        if ($_.Exception.Message -like "*already exists*") {
            Write-Host "ALREADY ASSIGNED" -ForegroundColor Yellow
        }
        else {
            Write-Host "FAILED" -ForegroundColor Red
            Write-Warning "  $($_.Exception.Message)"
        }
    }
}

# ── 3. Create a client secret ────────────────────────────────────────────────
Write-Host "`n[3/4] Creating client secret (1-year expiry)..." -ForegroundColor Yellow

$secret = Add-MgApplicationPassword -ApplicationId $app.Id -PasswordCredential @{
    DisplayName = "Automation secret"
    EndDateTime = (Get-Date).AddYears(1)
}

# ── 4. Grant admin consent ───────────────────────────────────────────────────
Write-Host "[4/4] Admin consent is granted via the app role assignments above." -ForegroundColor Yellow

# ── Summary ──────────────────────────────────────────────────────────────────
$context = Get-MgContext
Write-Host "`n=== Store these values securely ===" -ForegroundColor Cyan
Write-Host "  Tenant ID     : $($context.TenantId)" -ForegroundColor White
Write-Host "  Client ID     : $($app.AppId)" -ForegroundColor White
Write-Host "  Client Secret : $($secret.SecretText)" -ForegroundColor White
Write-Host ""
Write-Host "WARNING: The client secret is shown only once. Copy it now!" -ForegroundColor Red
Write-Host "Best practice: Store these values in Azure Key Vault.`n" -ForegroundColor Gray
