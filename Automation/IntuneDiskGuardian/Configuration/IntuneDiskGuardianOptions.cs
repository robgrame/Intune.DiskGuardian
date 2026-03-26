namespace IntuneDiskGuardian.Configuration;

/// <summary>
/// Strongly-typed configuration for the IntuneDiskGuardian worker.
/// Bound from the "IntuneDiskGuardian" section in appsettings.json.
/// </summary>
public sealed class IntuneDiskGuardianOptions
{
    public const string SectionName = "IntuneDiskGuardian";

    /// <summary>Azure AD / Entra tenant ID.</summary>
    public required string TenantId { get; set; }

    /// <summary>App Registration (client) ID.</summary>
    public required string ClientId { get; set; }

    /// <summary>
    /// App Registration client secret.
    /// For production, use Azure Key Vault or Managed Identity instead.
    /// </summary>
    public required string ClientSecret { get; set; }

    /// <summary>Object ID of the Entra group where low-disk devices are added.</summary>
    public required string EntraGroupId { get; set; }

    /// <summary>
    /// Intune Device Health Script (Proactive Remediation) ID.
    /// Find it in Graph: GET deviceManagement/deviceHealthScripts
    /// or in the Intune portal URL when viewing the remediation.
    /// </summary>
    public required string HealthScriptId { get; set; }

    /// <summary>Free disk space threshold in GB (must match the detection script). Default: 25.</summary>
    public double ThresholdGB { get; set; } = 25;

    /// <summary>Interval between sync cycles (default: 1 hour).</summary>
    public TimeSpan SyncInterval { get; set; } = TimeSpan.FromHours(1);
}
