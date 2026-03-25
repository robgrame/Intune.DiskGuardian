using DiskSpaceSync.Configuration;
using DiskSpaceSync.Services;
using Microsoft.Extensions.Options;

namespace DiskSpaceSync;

/// <summary>
/// Background worker that periodically syncs non-compliant Intune devices
/// into an Entra ID security group.
/// </summary>
public sealed class Worker(
    DeviceSyncService syncService,
    IOptions<DiskSpaceSyncOptions> options,
    ILogger<Worker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var config = options.Value;

        logger.LogInformation(
            "DiskSpaceSync worker started. Sync interval: {Interval}. Target group: {GroupId}.",
            config.SyncInterval, config.EntraGroupId);

        // Run immediately on startup, then on interval
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await syncService.SyncNonCompliantDevicesAsync(config.EntraGroupId, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                logger.LogError(ex, "Sync cycle failed. Will retry after {Interval}.", config.SyncInterval);
            }

            await Task.Delay(config.SyncInterval, stoppingToken);
        }

        logger.LogInformation("DiskSpaceSync worker stopping.");
    }
}
