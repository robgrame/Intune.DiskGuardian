using Microsoft.Graph;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;

namespace IntuneDiskGuardian.Services;

/// <summary>
/// Queries Intune via Microsoft Graph for non-compliant managed devices
/// and performs bidirectional sync with an Entra ID security group:
/// - Adds non-compliant devices to the group
/// - Removes devices that have become compliant
/// </summary>
public sealed class DeviceSyncService(
    GraphServiceClient graphClient,
    ILogger<DeviceSyncService> logger)
{
    /// <summary>
    /// Runs a full bidirectional sync cycle.
    /// </summary>
    public async Task SyncNonCompliantDevicesAsync(string entraGroupId, CancellationToken ct)
    {
        logger.LogInformation("Starting bidirectional device sync for group {GroupId}...", entraGroupId);

        // 1. Get all non-compliant managed devices from Intune
        var nonCompliantDevices = await GetNonCompliantDevicesAsync(ct);
        logger.LogInformation("Found {Count} non-compliant device(s) in Intune.", nonCompliantDevices.Count);

        // Build a set of non-compliant azureADDeviceIds for fast lookup
        var nonCompliantDeviceIds = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var d in nonCompliantDevices)
        {
            if (!string.IsNullOrEmpty(d.AzureADDeviceId))
                nonCompliantDeviceIds.Add(d.AzureADDeviceId);
        }

        // 2. Get current device members of the target group
        var existingMembers = await GetGroupDeviceMembersAsync(entraGroupId, ct);
        logger.LogInformation("Target group currently has {Count} device member(s).", existingMembers.Count);

        var existingDeviceIds = new HashSet<string>(
            existingMembers.Keys, StringComparer.OrdinalIgnoreCase);

        // 3. ADD non-compliant devices that are not yet in the group
        int added = 0, addSkipped = 0, addErrors = 0;

        foreach (var device in nonCompliantDevices)
        {
            var azureAdDeviceId = device.AzureADDeviceId;
            var deviceName = device.DeviceName ?? "unknown";

            if (string.IsNullOrEmpty(azureAdDeviceId))
            {
                logger.LogWarning("Device '{DeviceName}' has no AzureADDeviceId — skipping.", deviceName);
                addSkipped++;
                continue;
            }

            if (existingDeviceIds.Contains(azureAdDeviceId))
            {
                logger.LogDebug("Device '{DeviceName}' already in group — skipping add.", deviceName);
                addSkipped++;
                continue;
            }

            var entraObjectId = await ResolveEntraDeviceObjectIdAsync(azureAdDeviceId, deviceName, ct);
            if (entraObjectId is null)
            {
                addSkipped++;
                continue;
            }

            if (await TryAddDeviceToGroupAsync(entraGroupId, entraObjectId, deviceName, ct))
                added++;
            else
                addErrors++;
        }

        // 4. REMOVE devices from group that are now compliant
        int removed = 0, removeSkipped = 0, removeErrors = 0;

        foreach (var (deviceId, entraObjectId) in existingMembers)
        {
            if (nonCompliantDeviceIds.Contains(deviceId))
            {
                // Still non-compliant — keep in group
                removeSkipped++;
                continue;
            }

            // Device is no longer non-compliant — remove from group
            if (await TryRemoveDeviceFromGroupAsync(entraGroupId, entraObjectId, deviceId, ct))
                removed++;
            else
                removeErrors++;
        }

        logger.LogInformation(
            "Sync complete — Added: {Added}, Removed: {Removed}, " +
            "Add-Skipped: {AddSkipped}, Remove-Skipped: {RemoveSkipped}, " +
            "Add-Errors: {AddErrors}, Remove-Errors: {RemoveErrors}",
            added, removed, addSkipped, removeSkipped, addErrors, removeErrors);
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

    /// <summary>
    /// Returns a dictionary of deviceId → entraObjectId for all device members of the group.
    /// </summary>
    private async Task<Dictionary<string, string>> GetGroupDeviceMembersAsync(
        string groupId, CancellationToken ct)
    {
        var members = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);

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
                    if (!string.IsNullOrEmpty(device.DeviceId) && !string.IsNullOrEmpty(device.Id))
                        members[device.DeviceId] = device.Id;
                    return true;
                });

            await pageIterator.IterateAsync(ct);
        }

        return members;
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

    private async Task<bool> TryRemoveDeviceFromGroupAsync(
        string groupId, string deviceObjectId, string deviceId, CancellationToken ct)
    {
        try
        {
            await graphClient.Groups[groupId].Members[deviceObjectId].Ref
                .DeleteAsync(cancellationToken: ct);

            logger.LogInformation(
                "Removed device {DeviceId} (object {ObjectId}) from group — now compliant.",
                deviceId, deviceObjectId);
            return true;
        }
        catch (ODataError ex) when (ex.ResponseStatusCode == 404)
        {
            logger.LogDebug("Device {DeviceId} already removed from group (race condition).", deviceId);
            return true;
        }
        catch (Exception ex)
        {
            logger.LogError(ex, "Failed to remove device {DeviceId} from group.", deviceId);
            return false;
        }
    }
}
