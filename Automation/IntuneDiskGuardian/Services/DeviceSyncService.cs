using Microsoft.Graph;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;

namespace IntuneDiskGuardian.Services;

/// <summary>
/// Queries Intune via Microsoft Graph for non-compliant managed devices
/// and adds them to a designated Entra ID security group.
/// </summary>
public sealed class DeviceSyncService(
    GraphServiceClient graphClient,
    ILogger<DeviceSyncService> logger)
{
    /// <summary>
    /// Runs a full sync cycle: queries non-compliant devices from Intune,
    /// resolves their Entra device objects, and adds them to the target group.
    /// </summary>
    public async Task SyncNonCompliantDevicesAsync(string entraGroupId, CancellationToken ct)
    {
        logger.LogInformation("Starting non-compliant device sync to group {GroupId}...", entraGroupId);

        // 1. Get all non-compliant managed devices from Intune
        var nonCompliantDevices = await GetNonCompliantDevicesAsync(ct);
        logger.LogInformation("Found {Count} non-compliant device(s) in Intune.", nonCompliantDevices.Count);

        if (nonCompliantDevices.Count == 0)
            return;

        // 2. Get current device members of the target group (to skip duplicates)
        var existingDeviceIds = await GetGroupDeviceMembersAsync(entraGroupId, ct);
        logger.LogInformation("Target group already has {Count} device member(s).", existingDeviceIds.Count);

        // 3. Add missing devices to the group
        int added = 0, skipped = 0, errors = 0;

        foreach (var device in nonCompliantDevices)
        {
            var azureAdDeviceId = device.AzureADDeviceId;
            var deviceName = device.DeviceName ?? "unknown";

            if (string.IsNullOrEmpty(azureAdDeviceId))
            {
                logger.LogWarning("Device '{DeviceName}' has no AzureADDeviceId — skipping.", deviceName);
                skipped++;
                continue;
            }

            if (existingDeviceIds.Contains(azureAdDeviceId))
            {
                logger.LogDebug("Device '{DeviceName}' already in group — skipping.", deviceName);
                skipped++;
                continue;
            }

            // Look up the Entra directory device object
            var entraObjectId = await ResolveEntraDeviceObjectIdAsync(azureAdDeviceId, deviceName, ct);
            if (entraObjectId is null)
            {
                skipped++;
                continue;
            }

            // Add to group
            if (await TryAddDeviceToGroupAsync(entraGroupId, entraObjectId, deviceName, ct))
                added++;
            else
                errors++;
        }

        logger.LogInformation(
            "Sync complete — Added: {Added}, Skipped: {Skipped}, Errors: {Errors}",
            added, skipped, errors);
    }

    private async Task<List<ManagedDevice>> GetNonCompliantDevicesAsync(CancellationToken ct)
    {
        var devices = new List<ManagedDevice>();

        var response = await graphClient.DeviceManagement.ManagedDevices
            .GetAsync(config =>
            {
                config.QueryParameters.Filter = "complianceState eq 'noncompliant'";
                config.QueryParameters.Select =
                [
                    "id", "deviceName", "azureADDeviceId",
                    "complianceState", "freeStorageSpaceInBytes"
                ];
                config.QueryParameters.Top = 100;
            }, ct);

        if (response?.Value is not null)
        {
            var pageIterator = PageIterator<ManagedDevice, ManagedDeviceCollectionResponse>
                .CreatePageIterator(graphClient, response, device =>
                {
                    devices.Add(device);
                    return true;
                });

            await pageIterator.IterateAsync(ct);
        }

        return devices;
    }

    private async Task<HashSet<string>> GetGroupDeviceMembersAsync(string groupId, CancellationToken ct)
    {
        var deviceIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);

        var response = await graphClient.Groups[groupId].Members.GraphDevice
            .GetAsync(config =>
            {
                config.QueryParameters.Select = ["id", "deviceId"];
                config.QueryParameters.Top = 100;
            }, ct);

        if (response?.Value is not null)
        {
            var pageIterator = PageIterator<Device, DeviceCollectionResponse>
                .CreatePageIterator(graphClient, response, device =>
                {
                    if (!string.IsNullOrEmpty(device.DeviceId))
                        deviceIds.Add(device.DeviceId);
                    return true;
                });

            await pageIterator.IterateAsync(ct);
        }

        return deviceIds;
    }

    private async Task<string?> ResolveEntraDeviceObjectIdAsync(
        string azureAdDeviceId, string deviceName, CancellationToken ct)
    {
        try
        {
            var result = await graphClient.Devices
                .GetAsync(config =>
                {
                    config.QueryParameters.Filter = $"deviceId eq '{azureAdDeviceId}'";
                    config.QueryParameters.Select = ["id", "displayName", "deviceId"];
                }, ct);

            var entraDevice = result?.Value?.FirstOrDefault();
            if (entraDevice is null)
            {
                logger.LogWarning(
                    "Device '{DeviceName}' ({AzureAdDeviceId}) not found in Entra ID — skipping.",
                    deviceName, azureAdDeviceId);
                return null;
            }

            return entraDevice.Id;
        }
        catch (Exception ex)
        {
            logger.LogError(ex,
                "Failed to look up Entra device for '{DeviceName}' ({AzureAdDeviceId}).",
                deviceName, azureAdDeviceId);
            return null;
        }
    }

    private async Task<bool> TryAddDeviceToGroupAsync(
        string groupId, string deviceObjectId, string deviceName, CancellationToken ct)
    {
        try
        {
            var refBody = new ReferenceCreate
            {
                OdataId = $"https://graph.microsoft.com/v1.0/directoryObjects/{deviceObjectId}"
            };

            await graphClient.Groups[groupId].Members.Ref
                .PostAsync(refBody, cancellationToken: ct);

            logger.LogInformation("Added '{DeviceName}' to group.", deviceName);
            return true;
        }
        catch (ODataError ex) when (ex.ResponseStatusCode == 400)
        {
            logger.LogDebug("Device '{DeviceName}' already a member (race condition).", deviceName);
            return true;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to add '{DeviceName}' to group.", deviceName);
            return false;
        }
    }
}
