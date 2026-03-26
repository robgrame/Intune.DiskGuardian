<#
.SYNOPSIS
    Intune Proactive Remediation — Remediation Script (optional).
    Attempts to free disk space by cleaning common temp locations.

.DESCRIPTION
    This script runs automatically on devices where the detection script
    reported low disk space (exit code 1). It cleans:
    - Windows Temp folder
    - User Temp folder
    - Windows Update cache
    - Recycle Bin

    Deploy this as the "Remediation script" alongside Detect-LowDiskSpace.ps1.
    This script is OPTIONAL — the solution works without it.

.NOTES
    The remediation script always exits with code 0 (success) to avoid
    retry loops. Actual disk space recovery depends on what can be cleaned.
#>

$ErrorActionPreference = "SilentlyContinue"
$totalFreed = 0

function Remove-FolderContents {
    param([string]$Path, [string]$Label)
    if (Test-Path $Path) {
        $before = (Get-ChildItem $Path -Recurse -Force | Measure-Object -Property Length -Sum).Sum
        Remove-Item "$Path\*" -Recurse -Force -ErrorAction SilentlyContinue
        $after = (Get-ChildItem $Path -Recurse -Force | Measure-Object -Property Length -Sum).Sum
        $freed = [math]::Round(($before - $after) / 1MB, 2)
        if ($freed -gt 0) {
            Write-Output "Cleaned $Label — freed ${freed} MB"
        }
        return ($before - $after)
    }
    return 0
}

# Windows Temp
$totalFreed += Remove-FolderContents -Path "$env:SystemRoot\Temp" -Label "Windows Temp"

# User Temp
$totalFreed += Remove-FolderContents -Path $env:TEMP -Label "User Temp"

# Windows Update cache
$totalFreed += Remove-FolderContents -Path "$env:SystemRoot\SoftwareDistribution\Download" -Label "Windows Update cache"

# Empty Recycle Bin (requires COM)
try {
    Clear-RecycleBin -Force -ErrorAction SilentlyContinue
    Write-Output "Emptied Recycle Bin"
}
catch { }

$totalFreedMB = [math]::Round($totalFreed / 1MB, 2)
Write-Output "Total freed: ${totalFreedMB} MB"

exit 0
