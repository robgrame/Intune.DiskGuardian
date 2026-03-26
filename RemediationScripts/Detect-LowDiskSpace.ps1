<#
.SYNOPSIS
    Intune Proactive Remediation — Detection Script.
    Checks free disk space on the system drive and reports the result.

.DESCRIPTION
    This script runs on managed Windows devices via Intune Proactive Remediations.
    It checks the free space on the system drive (C:) and:
    - Exits with code 0 if free space >= threshold (device is OK)
    - Exits with code 1 if free space <  threshold (needs remediation)

    The JSON output is stored in Intune as preRemediationDetectionScriptOutput
    and can be queried via Graph API at:
    deviceManagement/deviceHealthScripts/{id}/deviceRunStates

.NOTES
    Deploy under: Intune > Devices > Remediations > Create script package
    Set as the "Detection script".
    Schedule: configure the desired frequency (e.g., every 1 hour, daily).
#>

$thresholdGB = 25

try {
    $systemDrive = $env:SystemDrive
    $drive = Get-PSDrive -Name $systemDrive.TrimEnd(':') -ErrorAction Stop
    $freeSpaceGB = [math]::Round($drive.Free / 1GB, 2)

    $output = @{
        FreeSpaceGB  = $freeSpaceGB
        ThresholdGB  = $thresholdGB
        SystemDrive  = $systemDrive
        ComputerName = $env:COMPUTERNAME
        Timestamp    = (Get-Date -Format "o")
    } | ConvertTo-Json -Compress

    Write-Output $output

    if ($freeSpaceGB -ge $thresholdGB) {
        exit 0  # OK — enough free space
    }
    else {
        exit 1  # Issue detected — low disk space
    }
}
catch {
    # On failure, report as issue so it gets flagged
    Write-Output (@{
        FreeSpaceGB  = 0
        ThresholdGB  = $thresholdGB
        SystemDrive  = $env:SystemDrive
        ComputerName = $env:COMPUTERNAME
        Timestamp    = (Get-Date -Format "o")
        Error        = $_.Exception.Message
    } | ConvertTo-Json -Compress)

    exit 1
}
