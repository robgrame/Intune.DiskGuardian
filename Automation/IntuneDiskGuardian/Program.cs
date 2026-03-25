using Azure.Identity;
using IntuneDiskGuardian;
using IntuneDiskGuardian.Configuration;
using IntuneDiskGuardian.Services;
using Microsoft.Extensions.Options;
using Microsoft.Graph;

var builder = Host.CreateApplicationBuilder(args);

// Bind configuration
builder.Services
    .AddOptions<IntuneDiskGuardianOptions>()
    .BindConfiguration(IntuneDiskGuardianOptions.SectionName)
    .ValidateOnStart();

// Register the Microsoft Graph client (client credentials flow)
builder.Services.AddSingleton(sp =>
{
    var config = sp.GetRequiredService<IOptions<IntuneDiskGuardianOptions>>().Value;

    var credential = new ClientSecretCredential(
        config.TenantId,
        config.ClientId,
        config.ClientSecret);

    return new GraphServiceClient(credential, ["https://graph.microsoft.com/.default"]);
});

// Register services
builder.Services.AddSingleton<DeviceSyncService>();
builder.Services.AddHostedService<Worker>();

var host = builder.Build();
host.Run();
