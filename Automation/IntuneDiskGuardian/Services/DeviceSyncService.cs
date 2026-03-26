using System.Text.Json;
using Microsoft.Graph;
using Microsoft.Graph.Models;
using Microsoft.Graph.Models.ODataErrors;
using Microsoft.Kiota.Abstractions;

namespace IntuneDiskGuardian.Services;

/// <summary>
/// Reads Intune Proactive Remediation (Device Health Script) run states
/// to identify devices with low disk space, then performs bidirectional
/// sync with an Entra ID security group.
/// </summary>
public sealed class DeviceSyncService(
    GraphServiceClient graphClient,
    ILogger<DeviceSyncService> logger)
{
    /// <summary>
    /// Runs a full bidirectional sync cycle based on remediation script results.
    /// </summary>
    public async Task SyncDevicesAsync(
        string entraGroupId,
        string healthScriptId,
        double thresholdGB,
        CancellationToken ct)
    {
        logger.LogInformation(
            "Starting bidirectional sync — HealthScript: {ScriptId}, Threshold: {Threshold} GB, Group: {GroupId}",
            healthScriptId, thresholdGB, entraGroupId);

        // 1. Query the health script run states to find devices with low disk space
        var lowDiskDeviceIds = await GetLowDiskDeviceIdsFromHealthScriptAsync(
            healthScriptId, thresholdGB, ct);

        logger.LogInformation("Found {Count} device(s) with low disk space from remediation results.",
            lowDiskDeviceIds.Count);

        // 2. Get current device members of the target group
        var existingMembers = await GetGroupDeviceMembersAsync(entraGroupId, ct);
        logger.LogInformation("Target group currently has {Count} device member(s).", existingMembers.Count);

        // 3. ADD low-disk devices that are not yet in the group
        int added = 0, addSkipped = 0, addErrors = 0;

        foreach (var (azureAdDeviceId, deviceName) in lowDiskDeviceIds)
        {
            if (existingMembers.ContainsKey(azureAdDeviceId))
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

        // 4. REMOVE devices from group that no longer have low disk space
        int removed = 0, removeSkipped = 0, removeErrors = 0;

        foreach (var (deviceId, entraObjectId) in existingMembers)
        {
            if (lowDiskDeviceIds.ContainsKey(deviceId))
            {
                removeSkipped++;
                continue;
            }

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

    /// <summary>
    /// Queries deviceHealthScripts/{id}/deviceRunStates to find devices where
    /// the detection script reported low disk space (detectionState = "fail"
    /// or parsed output FreeSpaceGB &lt; threshold).
    /// Returns a dictionary of azureADDeviceId → deviceName.
    /// </summary>
    private async Task<Dictionary<string, string>> GetLowDiskDeviceIdsFromHealthScriptAsync(
        string healthScriptId, double thresholdGB, CancellationToken ct)
    {
        var lowDiskDevices = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
        var nextLink =
            $"https://graph.microsoft.com/beta/deviceManagement/deviceHealthScripts/{healthScriptId}/deviceRunStates" +
            "?$expand=managedDevice($select=id,deviceName,azureADDeviceId)" +
            "&$select=detectionState,preRemediationDetectionScriptOutput" +
            "&$top=100";

        while (!string.IsNullOrEmpty(nextLink))
        {
            ct.ThrowIfCancellationRequested();

            var requestInfo = new RequestInformation
            {
                HttpMethod = Method.GET,
                URI = new Uri(nextLink)
            };

            var response = await graphClient.RequestAdapter.SendPrimitiveAsync<Stream>(
                requestInfo, cancellationToken: ct);

            if (response is null) break;

            using var doc = await JsonDocument.ParseAsync(response, cancellationToken: ct);
            var root = doc.RootElement;

            if (root.TryGetProperty("value", out var values))
            {
                foreach (var runState in values.EnumerateArray())
                {
                    ProcessRunState(runState, thresholdGB, lowDiskDevices);
                }
            }

            nextLink = root.TryGetProperty("@odata.nextLink", out var nl)
                ? nl.GetString()
                : null;
        }

        return lowDiskDevices;
    }

    private void ProcessRunState(
        JsonElement runState,
        double thresholdGB,
        Dictionary<string, string> lowDiskDevices)
    {
        // Get the managed device info from the $expand
        if (!runState.TryGetProperty("managedDevice", out var managedDevice))
            return;

        var azureAdDeviceId = managedDevice.TryGetProperty("azureADDeviceId", out var adId)
            ? adId.GetString() : null;
        var deviceName = managedDevice.TryGetProperty("deviceName", out var dn)
            ? dn.GetString() : "unknown";

        if (string.IsNullOrEmpty(azureAdDeviceId))
            return;

        // Check detectionState — "fail" means the detection script exited with code 1
        var detectionState = runState.TryGetProperty("detectionState", out var ds)
            ? ds.GetString() : null;

        bool isLowDisk = string.Equals(detectionState, "fail", StringComparison.OrdinalIgnoreCase);

        // Also try to parse the script output for a more accurate threshold check
        if (runState.TryGetProperty("preRemediationDetectionScriptOutput", out var outputProp))
        {
            var outputStr = outputProp.GetString();
            if (!string.IsNullOrWhiteSpace(outputStr))
            {
                try
                {
                    using var outputDoc = JsonDocument.Parse(outputStr);
                    if (outputDoc.RootElement.TryGetProperty("FreeSpaceGB", out var freeSpace))
                    {
                        var freeGB = freeSpace.GetDouble();
                        isLowDisk = freeGB < thresholdGB;

                        logger.LogDebug(
                            "Device '{DeviceName}': {FreeGB} GB free (threshold: {Threshold} GB) → {Status}",
                            deviceName, freeGB, thresholdGB, isLowDisk ? "LOW" : "OK");
                    }
                }
                catch (JsonException)
                {
                    // Output is not valid JSON — fall back to detectionState
                    logger.LogDebug(
                        "Device '{DeviceName}': could not parse script output, using detectionState={State}",
                        deviceName, detectionState);
                }
            }
        }

        if (isLowDisk)
        {
            lowDiskDevices[azureAdDeviceId] = deviceName ?? "unknown";
        }
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
                "Removed device {DeviceId} (object {ObjectId}) from group — disk space OK.",
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
