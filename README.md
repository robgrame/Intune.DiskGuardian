# Intune Disk Guardian

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![.NET](https://img.shields.io/badge/.NET-10.0-purple)](https://dotnet.microsoft.com/)
[![Azure](https://img.shields.io/badge/Azure-Logic%20App%20%7C%20Graph%20API-0078D4)](https://azure.microsoft.com/)

Automated solution for **Microsoft Intune** that detects Windows devices with low free disk space, marks them as **non-compliant** via a Custom Compliance Policy, and performs **bidirectional sync** with an **Entra ID security group**: non-compliant devices are added, and devices that become compliant again are automatically removed.

---

## ✨ What's Included

| Component | Path | Description |
|-----------|------|-------------|
| **Custom Compliance Policy** | `ComplianceScripts/` | Intune detection script + compliance JSON — flags devices with < 25 GB free |
| **Azure Logic App (Bicep)** | `main.bicep` | Serverless Logic App that reads Intune inventory and adds low-disk devices to an Entra group |
| **.NET 10 Worker Service** | `Automation/IntuneDiskGuardian/` | Long-running background service — bidirectional sync: adds non-compliant devices, removes compliant ones |
| **PowerShell Automation** | `Automation/` | Standalone scripts for the same bidirectional sync + Windows Scheduled Task setup |
| **App Registration** | `Automation/Register-App.ps1` | Creates the Entra app with least-privilege Graph permissions |
| **Graph Permissions** | `grant-graph-permissions.ps1` | Grants Graph API permissions to the Logic App's Managed Identity |

---

## 🏗️ Architecture

```
┌────────────────────┐      ┌──────────────────────┐      ┌────────────────────────┐
│  Intune Custom     │      │  .NET Worker Service  │      │  Entra ID Group        │
│  Compliance Policy │      │  (or Logic App /      │      │  "Devices-LowDisk"     │
│                    │      │   PowerShell script)  │      │                        │
│  Check-DiskSpace   │      │                       │      │  Targeted policies:    │
│  runs on device    │─────►│  Queries Graph API    │─────►│  - Cleanup scripts     │
│  < 25 GB = fail    │      │  for non-compliant    │      │  - Conditional Access  │
│                    │      │  devices & removes    │      │  - Notifications       │
│                    │      │  compliant ones       │      │                        │
└────────────────────┘      └──────────────────────┘      └────────────────────────┘
```

**Three deployment options** — pick the one that fits your environment:

| Option | Best for | Runs on |
|--------|----------|---------|
| **A — .NET Worker Service** | Enterprises needing a robust, long-running service | Windows Server / Container / Azure Container Apps |
| **B — PowerShell Scheduled Task** | Simple on-prem deployments | Windows Server (Task Scheduler) |
| **C — Azure Logic App** | Fully serverless, zero infrastructure | Azure (Consumption plan) |

---

## 📋 Prerequisites

- **Azure subscription** (Contributor on target Resource Group — for Logic App option)
- **Microsoft Intune** with enrolled Windows devices
- **Entra ID** permissions to create security groups and app registrations
- **.NET 10 SDK** — for the Worker Service ([download](https://dotnet.microsoft.com/download))
- **Azure CLI** + **Bicep CLI** — for the Logic App option
- **Microsoft Graph PowerShell SDK**:
  ```powershell
  Install-Module Microsoft.Graph -Scope CurrentUser
  ```

---

## 🚀 Quick Start

### Step 1 — Deploy the Custom Compliance Policy in Intune

1. **Intune admin center** → Devices → Compliance → Scripts → **Add** (Windows 10 and later)
2. Upload `ComplianceScripts/Check-DiskSpace.ps1` as the **Discovery script**
3. Compliance policies → **Create policy** → Windows 10+ → **Custom Compliance**
4. Select the discovery script → upload `ComplianceScripts/DiskSpace-CompliancePolicy.json`
5. Assign the policy to your device groups

Devices with less than **25 GB** free on the system drive will be flagged as **non-compliant**. When a device frees up space and becomes compliant again, it will be **automatically removed** from the group at the next sync cycle.

### Step 2 — Create the App Registration

```powershell
.\Automation\Register-App.ps1
```

Save the output (`TenantId`, `ClientId`, `ClientSecret`) securely — ideally in **Azure Key Vault**.

### Step 3 — Run the Automation

#### Option A — .NET 10 Worker Service

```bash
cd Automation/IntuneDiskGuardian

# Store secrets with .NET User Secrets (never in appsettings.json)
dotnet user-secrets set "IntuneDiskGuardian:TenantId"     "<YOUR-TENANT-ID>"
dotnet user-secrets set "IntuneDiskGuardian:ClientId"      "<YOUR-CLIENT-ID>"
dotnet user-secrets set "IntuneDiskGuardian:ClientSecret"   "<YOUR-CLIENT-SECRET>"
dotnet user-secrets set "IntuneDiskGuardian:EntraGroupId"   "<YOUR-GROUP-OBJECT-ID>"

dotnet run
```

Configuration in `appsettings.json`:

```jsonc
{
  "IntuneDiskGuardian": {
    "TenantId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "ClientId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "ClientSecret": "use-user-secrets-or-keyvault",
    "EntraGroupId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "SyncInterval": "01:00:00"
  }
}
```

#### Option B — PowerShell Scheduled Task

```powershell
.\Automation\Setup-ScheduledTask.ps1 `
    -TenantId     "<TENANT-ID>" `
    -ClientId     "<CLIENT-ID>" `
    -ClientSecret "<CLIENT-SECRET>" `
    -EntraGroupId "<GROUP-ID>" `
    -ScriptPath   "C:\Scripts\Sync-NonCompliantDevices.ps1"
```

#### Option C — Azure Logic App (Serverless)

```bash
az group create --name rg-intune-disk-guardian --location westeurope

az deployment group create \
  --resource-group rg-intune-disk-guardian \
  --template-file main.bicep \
  --parameters main.bicepparam

# Grant Graph permissions to Managed Identity (from deployment output)
.\grant-graph-permissions.ps1 -ManagedIdentityObjectId "<MI-OBJECT-ID>"
```

---

## 🔐 Required Graph API Permissions

| Permission | Type | Purpose |
|------------|------|---------|
| `DeviceManagementManagedDevices.Read.All` | Application | Read Intune device inventory and compliance state |
| `DeviceManagementConfiguration.Read.All` | Application | Read compliance policy details |
| `GroupMember.ReadWrite.All` | Application | Add/remove devices in the Entra group |
| `Device.Read.All` | Application | Resolve device objects in Entra ID |

All permissions follow the **least-privilege** principle. The `Register-App.ps1` script assigns them automatically with admin consent.

---

## 🔧 Customization

### Change the Disk Space Threshold

Edit `ComplianceScripts/DiskSpace-CompliancePolicy.json`:

```json
{
  "SettingName": "FreeSpaceGB",
  "Operator": "IsGreaterEqual",
  "Operand": 25
}
```

Change `25` to your desired threshold in GB.

### Change the Sync Interval (.NET Worker)

In `appsettings.json` or via environment variable:

```json
"SyncInterval": "00:30:00"
```

Format: `HH:mm:ss` (e.g., `00:30:00` = every 30 minutes).

---

## 🧪 Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| **401 Unauthorized** | Graph permissions not yet propagated | Wait 15–30 min after granting permissions |
| **403 Forbidden** | Missing application permissions | Re-run `Register-App.ps1` or `grant-graph-permissions.ps1` |
| Device not flagged | `freeStorageSpaceInBytes` is 0 or null | Verify device is enrolled and syncing with Intune |
| **400 Bad Request** on group add | Device already in group | Expected behavior — silently skipped |
| No devices processed | All devices are compliant | Check compliance state in Intune admin center |

---

## 🗂️ Project Structure

```
CheckDiskSpace/
├── ComplianceScripts/
│   ├── Check-DiskSpace.ps1              # Intune detection script (runs on device)
│   └── DiskSpace-CompliancePolicy.json  # Compliance rule definition
├── Automation/
│   ├── Register-App.ps1                 # App Registration setup
│   ├── Sync-NonCompliantDevices.ps1     # PowerShell sync script
│   ├── Setup-ScheduledTask.ps1          # Scheduled Task installer
│   └── IntuneDiskGuardian/                   # .NET 10 Worker Service
│       ├── Program.cs
│       ├── Worker.cs
│       ├── Configuration/
│       │   └── IntuneDiskGuardianOptions.cs
│       ├── Services/
│       │   └── DeviceSyncService.cs
│       └── appsettings.json
├── main.bicep                           # Logic App infrastructure (Bicep)
├── main.bicepparam                      # Deployment parameters
├── main.json                            # Compiled ARM template
└── grant-graph-permissions.ps1          # Graph permissions for Managed Identity
```

---

## 🔒 Security Best Practices

- **Never commit secrets** to source control — use `.NET User Secrets` or `Azure Key Vault`
- For production, prefer **certificate-based authentication** over client secrets
- The App Registration uses **least-privilege** application permissions
- Rotate client secrets before expiry (default: 1 year)
- The Logic App uses a **System-assigned Managed Identity** (no secrets to manage)

---

## 📄 License

This project is licensed under the [MIT License](LICENSE).

---

## 🤝 Contributing

Contributions are welcome! Please open an issue or submit a pull request.
