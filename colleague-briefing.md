## IntuneDiskGuardian — Solution Overview (for colleagues)

**IntuneDiskGuardian** is an automated solution that monitors free disk space on Intune-managed Windows devices and dynamically manages an Entra ID security group based on the results.

### How It Works

The solution has two parts:

**1. Detection (runs on each device)**

An Intune **Proactive Remediation** (Device Health Script) is deployed to all target devices. The detection script (`Detect-LowDiskSpace.ps1`) runs on a schedule you configure in Intune (e.g., every hour), checks the free space on the system drive, and reports a JSON result back to Intune:
- **Exit 0** → disk space is OK (≥ 25 GB free)
- **Exit 1** → disk space is low (< 25 GB free)

An optional remediation script (`Remediate-LowDiskSpace.ps1`) can automatically clean temp files, Windows Update cache, and the Recycle Bin when low space is detected.

**2. Group Sync (runs centrally)**

A **.NET 10 Worker Service** (or equivalent PowerShell script) runs on a schedule and:
1. Queries the Microsoft Graph API for the Proactive Remediation run states (`deviceHealthScripts/{id}/deviceRunStates`)
2. Parses each device's detection script output to read the actual free space value
3. Compares it against a configurable threshold (default: 25 GB)
4. **Adds** devices below the threshold to a designated Entra ID security group
5. **Removes** devices that have recovered above the threshold

This **bidirectional sync** ensures the group always reflects the current state — devices come and go automatically.

### Why This Approach

We chose Proactive Remediations over Custom Compliance Policies because:
- **You control the schedule** — compliance policy evaluation timing is unpredictable
- **Queryable output** — the detection script's JSON output is stored in Intune and accessible via Graph API
- **Built-in remediation** — you can optionally auto-clean disk space on affected devices
- **Fewer permissions** — only 3 Graph API permissions needed (vs. 4 previously)

### What You Can Do With the Entra Group

Once devices are in the group, you can target them with:
- **Conditional Access** — restrict access until disk space is freed
- **Intune Remediation Scripts** — deploy additional cleanup actions
- **Alerts & Reporting** — monitor the group size for trends
- **User Notifications** — push Company Portal messages to affected users

### Required Graph API Permissions

| Permission | Purpose |
|------------|---------|
| `DeviceManagementConfiguration.Read.All` | Read remediation script run states |
| `GroupMember.ReadWrite.All` | Add/remove devices from the Entra group |
| `Device.Read.All` | Resolve device objects in Entra ID |

### Deployment Options

| Option | Technology | Best For |
|--------|-----------|----------|
| .NET Worker Service | .NET 10 BackgroundService | Enterprise — robust, monitorable, containerizable |
| PowerShell Scheduled Task | PowerShell + Task Scheduler | Simple on-prem environments |
| Azure Logic App | Bicep / ARM | Fully serverless (Note: still uses the older inventory-based approach) |

### Repository

📦 https://github.com/robgrame/IntuneDiskGuardian
