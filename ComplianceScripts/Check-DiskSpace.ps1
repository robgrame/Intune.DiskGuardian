<#
.SYNOPSIS
    Intune Custom Compliance Policy — Disk Space Detection Script.

.DESCRIPTION
    This script runs on managed Windows devices via Intune and returns a JSON
    object containing the free disk space (in GB) of the system drive (C:).
    Intune evaluates the returned JSON against a companion compliance policy
    JSON to determine whether the device is compliant.

    The script MUST output a single JSON object to stdout. Any other output
    (Write-Host, Write-Warning, etc.) is ignored by the Intune agent.

.NOTES
    Deploy this script as a "Discovery script" under:
    Devices > Compliance > Scripts > Add (Windows 10 and later)

    Pair it with the companion JSON file (DiskSpace-CompliancePolicy.json)
    when creating the Custom Compliance policy.
#>

$ErrorActionPreference = "Stop"

try {
    # Get the system drive (typically C:)
    $systemDrive = $env:SystemDrive  # e.g. "C:"
    $drive = Get-PSDrive -Name $systemDrive.TrimEnd(':') -ErrorAction Stop

    # FreeSpace is in bytes; convert to GB (rounded to 2 decimal places)
    $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)

    # Return JSON — Intune reads this and evaluates it against the compliance JSON
    $result = @{
        FreeSpaceGB = $freeSpaceGB
    }

    return $result | ConvertTo-Json -Compress
}
catch {
    # On failure, report 0 GB so the device is flagged as non-compliant
    $result = @{
        FreeSpaceGB = 0
    }

    return $result | ConvertTo-Json -Compress
}
