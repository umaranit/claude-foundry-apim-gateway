# Claude on Azure gateway: prerequisites checklist

Complete this checklist **before** the deployment session. Each item takes a few minutes, and together they avoid the most common blockers.

## What will be deployed

The gateway puts Azure API Management (APIM) in front of the Claude models in your Microsoft Foundry resource. Users sign in with Microsoft Entra ID. The gateway checks their role, applies per-user and per-team budgets, and records usage in Log Analytics.

**Azure resources** (in one gateway resource group):

| Resource | Purpose | Billing |
|---|---|---|
| API Management (Standard v2) | The gateway endpoint and its policies | Hourly |
| Function App plan (Elastic Premium EP1, 2 always-ready instances) with two Function Apps | Budget API and usage processor | Hourly |
| Azure Cache for Redis | Fast budget and price lookups | Hourly |
| Azure Cosmos DB | Budget state | Usage-based |
| Event Hubs namespace | Usage events from the gateway | Hourly |
| Storage account, Application Insights | Function storage and monitoring | Usage-based |
| Data collection rule, workbook (in the workspace's resource group) | Pricing data and the usage dashboard | Usage-based |
| Azure Managed Grafana (optional) | Extra dashboards | Hourly plus per user |

**Microsoft Entra ID objects:**

| Object | Purpose |
|---|---|
| Gateway API app registration and service principal | Issues the tokens the gateway checks. Defines the roles `Claude.User`, `Claude.Tier.Pro`, `Claude.Tier.Basic`, `Claude.Suspended`, plus team and team-profile roles. |
| "Claude Desktop - &lt;APIM name&gt;" app registration | Public client used by Claude Desktop to sign users in |
| "Claude Budget API - &lt;prefix&gt;" app registration | Protects the internal budget API |
| One security group per team ("Claude Team - &lt;team name&gt;") | Gives team members their roles |

## Checklist

| # | Item | Owner | How to check |
|---|---|---|---|
| 1 | **Deployment machine:** Linux (Ubuntu, WSL on Windows, or a Linux VM), or Windows with PowerShell 7.3+. Not Git Bash. | Admin | See the deployment guide, Part B |
| 2 | **Entra rights** to create app registrations, app roles and security groups (Application Administrator, or Cloud Application Administrator plus Groups Administrator) | Entra admin | `az ad app list --top 1` works after sign-in |
| 3 | **Azure rights** on the subscription: Owner, or Contributor plus User Access Administrator. The deployment creates role assignments. | Azure admin | `az role assignment list --assignee <user-object-id> --scope /subscriptions/<subscription-id> -o table` |
| 4 | **Sign-in from the deployment machine works.** If Conditional Access requires a managed device, use browser sign-in from that device, not a device code. | Admin | `az login --tenant <tenant-id>` |
| 5 | **Gateway resource group**: an existing one, or create it during deployment (deployment guide, step B2) | Azure admin | `az group show -n <resource-group>` |
| 6 | **Log Analytics workspace** in the same subscription: an existing one (note its region), or create it during deployment (step B2) | Azure admin | `az resource show --ids <workspace-resource-id> --query location -o tsv` |
| 7 | **Microsoft Foundry resource** with **exactly one** deployment each of Claude Opus, Sonnet and Haiku | AI admin | `az cognitiveservices account deployment list -g <foundry-rg> -n <foundry-name> --query "[].{deployment:name, model:properties.model.name}" -o table` |
| 8 | **Resource providers registered** (Microsoft.Quota, ApiManagement, Web, Cache, DocumentDB, EventHub, Insights, OperationalInsights, Storage, Dashboard) | Azure admin | Deployment guide, step B4 |
| 9 | **EP1 quota**: at least 2 free instances in the region | Azure admin | Deployment guide, step B5 |
| 10 | **Model prices** in `snippets/15-load-pricing.py` checked against your Azure agreement | Account / finance | Review the `PRICES` table |
| 11 | **Team list**: team names, member sign-in names (UPNs), profile (`regular` or `power`), default user tier (`pro`, `basic` or `lite`), allowed models | Business owner | Fill in the table below |
| 11a | **Team governance mode**: `enforce` (default) blocks anyone who is not in exactly one team and blocks models outside a team's allow-list; `observe` records team identity problems without blocking. Decide which one to start with. | Business owner + admin | See "Team governance mode" below |
| 12 | **Developer access through Azure CLI** (Claude Code CLI and VS Code use Azure CLI to get tokens): add Azure CLI as an authorized client of the gateway API, or have an Entra admin grant consent | Entra admin | Operations guide, "Allow Azure CLI to request gateway tokens" |
| 13 | **Claude Desktop sign-in consent** for `openid profile offline_access`, if your tenant blocks user consent | Entra admin | Grant admin consent to the "Claude Desktop" app after deployment if users see "Need admin approval" |
| 14 | **Grafana admin** (only if Grafana is wanted): the Entra **user object ID** of the admin, in this tenant | Admin | `az ad signed-in-user show --query id -o tsv` (for yourself) or `az ad user show --id <upn> --query id -o tsv` |

## Names to decide (keep them the same on every re-run)

| Setting | Rule | Your value |
|---|---|---|
| Gateway resource group | Existing, or created in step B2 | |
| Region | Same region for APIM, the budget platform and Cosmos | |
| APIM name | Globally unique | |
| Resource name prefix | 3–11 lowercase letters or digits | |
| Gateway app name | Use the **same name** in the app script and the setup script. The default is "Claude Gateway - &lt;APIM name&gt;". | |
| Log Analytics workspace resource ID | `/subscriptions/<id>/resourceGroups/<rg>/providers/Microsoft.OperationalInsights/workspaces/<name>` | |
| Foundry resource group and name | Existing | |
| Publisher email and name | Shown in APIM | |

## Team governance mode

The deployment uses **`enforce`** by default:

| Control | `off` | `observe` | `enforce` (default) |
|---|---|---|---|
| Suspended users blocked (`Claude.Suspended`) | Yes | Yes | Yes |
| Per-user budget and token limits (tier) | Yes | Yes | Yes |
| Team budget and team token limits (profile) | No | Yes | Yes |
| Users with no team, more than one team, or a mismatched profile role are blocked | No | No (logged only) | **Yes** |
| Team model allow-list (`allowedModels`) | No | No | **Yes** |

In `enforce` mode, **every user must be in exactly one team** (a team of one person is fine). Choose `observe` first if you want to review team assignments in the usage workbook before anyone is blocked; switching later is described in the operations guide.

## Team list template

| Team name | Members (sign-in names, comma-separated) | Profile (regular / power) | Default user tier (pro / basic / lite) | Allowed models (sonnet, haiku, opus) |
|---|---|---|---|---|
| | | | | |

A user can belong to only one team, and in `enforce` mode every user must belong to one. Default budgets are in `admin/setup.example.json` (`tiersConfig` for users, `teamGovernance.profiles` for teams) and can be changed before deployment.
