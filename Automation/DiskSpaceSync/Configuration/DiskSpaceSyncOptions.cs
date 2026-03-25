namespace DiskSpaceSync.Configuration;

/// <summary>
/// Strongly-typed configuration for the DiskSpaceSync worker.
/// Bound from the "DiskSpaceSync" section in appsettings.json.
/// </summary>
public sealed class DiskSpaceSyncOptions
{
    public const string SectionName = "DiskSpaceSync";

    /// <summary>Azure AD / Entra tenant ID.</summary>
    public required string TenantId { get; set; }

    /// <summary>App Registration (client) ID.</summary>
    public required string ClientId { get; set; }

    /// <summary>
    /// App Registration client secret.
    /// For production, use Azure Key Vault or Managed Identity instead.
    /// </summary>
    public required string ClientSecret { get; set; }

    /// <summary>Object ID of the Entra group where non-compliant devices are added.</summary>
    public required string EntraGroupId { get; set; }

    /// <summary>Interval between sync cycles (default: 1 hour).</summary>
    public TimeSpan SyncInterval { get; set; } = TimeSpan.FromHours(1);
}
