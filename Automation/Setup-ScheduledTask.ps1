<#
.SYNOPSIS
    Creates a Windows Scheduled Task to run Sync-NonCompliantDevices.ps1 daily.

.DESCRIPTION
    Sets up a Scheduled Task that runs the sync script once per day. Credentials
    are stored as environment variables accessible only to the SYSTEM account.

.PARAMETER TenantId
    Entra tenant ID.

.PARAMETER ClientId
    App Registration client ID.

.PARAMETER ClientSecret
    App Registration client secret.

.PARAMETER EntraGroupId
    Object ID of the target Entra group.

.PARAMETER TaskName
    Name of the Scheduled Task (default: "Intune-DiskSpace-Sync").

.PARAMETER ScriptPath
    Full path to Sync-NonCompliantDevices.ps1.

.EXAMPLE
    .\Setup-ScheduledTask.ps1 `
        -TenantId "xxxxxxxx-..." `
        -ClientId "xxxxxxxx-..." `
        -ClientSecret "secret" `
        -EntraGroupId "xxxxxxxx-..." `
        -ScriptPath "C:\Scripts\Sync-NonCompliantDevices.ps1"

.NOTES
    Must be run as Administrator.
    For production, consider using Azure Key Vault or a certificate instead
    of storing the client secret in the task arguments.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TenantId,
    [Parameter(Mandatory)][string]$ClientId,
    [Parameter(Mandatory)][string]$ClientSecret,
    [Parameter(Mandatory)][string]$EntraGroupId,
    [Parameter(Mandatory)][string]$HealthScriptId,
    [double]$ThresholdGB = 25,
    [string]$TaskName = "IntuneDiskGuardian",
    [Parameter(Mandatory)][string]$ScriptPath
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $ScriptPath)) {
    Write-Error "Script not found: $ScriptPath"
    exit 1
}

$arguments = @(
    "-NoProfile"
    "-NonInteractive"
    "-ExecutionPolicy Bypass"
    "-File `"$ScriptPath`""
    "-TenantId `"$TenantId`""
    "-ClientId `"$ClientId`""
    "-ClientSecret `"$ClientSecret`""
    "-EntraGroupId `"$EntraGroupId`""
    "-HealthScriptId `"$HealthScriptId`""
    "-ThresholdGB $ThresholdGB"
) -join " "

$action = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument $arguments

# Run daily at 06:00
$trigger = New-ScheduledTaskTrigger -Daily -At "06:00"

$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -RunOnlyIfNetworkAvailable `
    -RestartCount 3 `
    -RestartInterval (New-TimeSpan -Minutes 10)

$principal = New-ScheduledTaskPrincipal `
    -UserId "SYSTEM" `
    -LogonType ServiceAccount `
    -RunLevel Highest

Register-ScheduledTask `
    -TaskName $TaskName `
    -Action $action `
    -Trigger $trigger `
    -Settings $settings `
    -Principal $principal `
    -Description "IntuneDiskGuardian — Syncs non-compliant (low disk space) devices to an Entra ID group." `
    -Force

Write-Host "`nScheduled Task '$TaskName' created successfully." -ForegroundColor Green
Write-Host "Schedule: Daily at 06:00 (runs as SYSTEM)." -ForegroundColor Gray
Write-Host "`nIMPORTANT: The client secret is stored in the task arguments." -ForegroundColor Yellow
Write-Host "For production, migrate to certificate-based auth or Azure Key Vault.`n" -ForegroundColor Yellow
