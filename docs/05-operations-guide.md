# Claude on Azure gateway: operations guide

Day-2 tasks for administrators after the deployment. Commands are shown for Linux (Bash) and Windows (PowerShell 7); run them from the repository folder with the same `admin/setup.local.json` used for the deployment.

> Keep `admin/setup.local.json` safe and **do not commit it** to source control. It holds your tenant, subscription, resource names and team member names. The same applies to `developer/claude-client-configuration.json` and the `logs` folder.

---

## 1. Access and consent

### Allow Azure CLI to request gateway tokens
Claude Code CLI and the VS Code extension get their gateway token through Azure CLI. In tenants that block user consent, developers otherwise see **"Need admin approval – Microsoft Azure CLI"**. Choose one of these options:

The setup does this automatically (option `preAuthorizeAzureCli`, default on): it adds Azure CLI as an authorized client of the gateway API on every full run and export. Use the steps below only to check it, to repair it, or if you turned the option off.

**Option A: authorized client application (set by the gateway app owner)**
1. Azure portal > **Microsoft Entra ID** > **App registrations** > **All applications** > the gateway app ("Claude Gateway - &lt;APIM name&gt;").
2. **Expose an API** > **Authorized client applications** > **Add a client application**.
3. Client ID: `04b07795-8ddb-461a-bbee-02f9e1bf7b46` (Microsoft Azure CLI; the same ID in every tenant). Do not enter the gateway app ID or the Claude Desktop app ID.
4. Select the `access_as_user` scope > **Add application**.
5. Check: `az ad app show --id <gateway-app-id> --query "api.preAuthorizedApplications[].appId" -o tsv` must list `04b07795-8ddb-461a-bbee-02f9e1bf7b46`. If "Need admin approval" still appears, this ID is missing or was added to the wrong app.

**Option B: admin consent.** An Entra administrator grants tenant-wide consent for Azure CLI to call the gateway API.

Either way, users still need the `Claude.User` role to use the gateway.

### Grant consent for Claude Desktop (only if needed)
The gateway scope is already pre-authorized for the Desktop app. If users still see "Need admin approval" in Claude Desktop (for `openid profile offline_access`), an Entra administrator opens **Enterprise applications** > "Claude Desktop - &lt;APIM name&gt;" > **Permissions** > **Grant admin consent**.

---

## 2. Teams and users

### How access works
- Each team is an Entra security group, "Claude Team - &lt;team name&gt;".
- The group is assigned the roles `Claude.User`, the team role, the team-profile role (`Claude.TeamProfile.Regular` or `Claude.TeamProfile.Power`) and the default user tier role (`Claude.Tier.Pro`, `Claude.Tier.Basic` or `Claude.Tier.Lite`).
- Usage is attributed to the user and the team, and shown in the **Claude team governance** workbook.
- A user can belong to only one team.
- A team's `allowedModels` use the model names (`claude-sonnet-5`, `claude-haiku-4-5`, `claude-opus-5`). The setup adds the matching Foundry deployment names automatically, so deployments can have any name. If you add or rename a deployment in Foundry, run the governance script with `--yes` / `-Yes` again so the gateway learns the new name.

### Check the current state (read-only)
```bash
./admin/setup-teams-governance-claude-gateway.sh --config admin/setup.local.json --check
```
```powershell
.\admin\setup-teams-governance-claude-gateway.ps1 -ConfigPath admin\setup.local.json -Check
```
It reports missing groups, members and role assignments ("drift"), and members in a group who are not in the configuration (`extraMembers`).

### Add members to an existing team
Add the sign-in names to the team's `members` list in `admin/setup.local.json`, then:
```bash
./admin/setup-teams-governance-claude-gateway.sh --config admin/setup.local.json --yes
```
```powershell
.\admin\setup-teams-governance-claude-gateway.ps1 -ConfigPath admin\setup.local.json -Yes
```

### Add a new team
Add an entry under `teamGovernance.teams` in `admin/setup.local.json`:
```json
{
  "id": "data-science",
  "displayName": "Data Science",
  "groupDisplayName": "Claude Team - Data Science",
  "teamRoleValue": "data-science.regular",
  "profile": "regular",
  "defaultUserTier": "basic",
  "allowedModels": ["claude-sonnet-5", "claude-haiku-4-5"],
  "members": ["user1@contoso.com", "user2@contoso.com"]
}
```
Rules: `id` is 3–50 lowercase letters, digits or hyphens; `profile` must exist under `teamGovernance.profiles`; `defaultUserTier` is `pro`, `basic` or `lite`; `allowedModels` uses the names `claude-sonnet-5`, `claude-haiku-4-5`, `claude-opus-5`; a member can be in only one team.

Validate, then re-run the full deployment (same command as the deployment guide). It updates Entra, the gateway's team settings and the budget platform, and keeps existing resources:
```bash
jq -e -f admin/validate-config.jq admin/setup.local.json > /dev/null && echo "Config OK"
```

### Remove a member or a team
The scripts **never** delete groups or remove members. Remove the user from the team's Entra group (Microsoft Entra ID > Groups), and remove them from `members` in the configuration so the check stays clean. To retire a team, remove its group's members, then delete the group and remove the team from the configuration.

### Move a user to another team
1. Remove the user from the **old** team's group (Microsoft Entra ID > Groups) and from its `members` list in the configuration.
2. Add the user to the new team's `members` list and run the governance script with `--yes` / `-Yes`.
3. The user signs in again to get a fresh token.

Until step 1 is done, the user holds two team roles; in `enforce` mode they are blocked (403 `identity`).

### Give access to a single user
In `enforce` mode, every user must be in exactly one team. Add the user to an existing team, or create a team with one member.
In `observe` or `off` mode only, you can instead assign roles directly: Microsoft Entra ID > **Enterprise applications** > the gateway app > **Users and groups** > **Add user/group**: assign `Claude.User` and one tier role (`Claude.Tier.Pro` or `Claude.Tier.Basic`; `Claude.Tier.Lite` exists only when a team uses the lite tier).

### Suspend a user
Assign the `Claude.Suspended` role to the user on the gateway app (Enterprise applications > the gateway app > Users and groups). The user is blocked (403 `admin`) once they get a fresh token; an existing token keeps working until it expires (up to about an hour). Remove the role to restore access.

Role changes of any kind (team, tier, suspension) take effect only in a newly issued token.

---

## 3. Budgets, limits and prices

| What | Where in `admin/setup.local.json` | Fields |
|---|---|---|
| Per-user tiers | `tiersConfig` (exactly `pro`, `basic`, `lite`) | `tpm` (tokens per minute), `tokenQuota`, `costQuota` (USD) |
| Team profiles | `teamGovernance.profiles` | `tpm`, `tokenQuota`, `costQuota` (USD) |
| Model prices | `snippets/15-load-pricing.py` (`PRICES`) | Price per token type and model |

After a change, validate the configuration and re-run the full deployment with the same names.

### Team governance mode
Set in `teamGovernance.mode`. The default is `enforce`.

| Control | `off` | `observe` | `enforce` (default) |
|---|---|---|---|
| Suspended users blocked (`Claude.Suspended`) | Yes | Yes | Yes |
| Per-user budget and token limits (tier) | Yes | Yes | Yes |
| Team budget and team token limits (profile) | No | Yes | Yes |
| Users with no team, more than one team, or a mismatched profile role are blocked | No | No (logged only) | **Yes** |
| Team model allow-list (`allowedModels`) | No | No | **Yes** |

**Switch mode:** change `teamGovernance.mode`, validate the configuration, and re-run the full deployment with the same names. To roll back from `enforce`, set `observe`; individual controls and team budgets stay active.

### What users see when they are blocked
Every denial carries the header `x-claude-denied-by`:

| Status | `x-claude-denied-by` | Reason |
|---|---|---|
| 403 | `admin` | User has `Claude.Suspended` |
| 403 | `identity` | `enforce` mode: user has no team, more than one team, or a team/profile mismatch |
| 403 | `team-model-policy` | `enforce` mode: model is not in the team's `allowedModels` |
| 403 | `user-budget` / `team-budget` | Monthly user or team dollar budget used up |
| 429 or 403 | `user-token-limit` / `team-token-limit` | Rate (tokens per minute) or monthly token quota reached |

Budget accounting is asynchronous and fail-open: usage is counted shortly after each request, so a user can go slightly over a limit before it is enforced, and if the budget service is unavailable, requests are allowed. Cache writes are not counted.

---

## 4. Client settings, reporting and Grafana

### Re-export the client configuration
For example after changing model deployments:
```bash
./admin/claude-gateway-setup.sh --config admin/setup.local.json --non-interactive --stage export --yes
```
```powershell
.\admin\claude-gateway-setup.ps1 -ConfigPath admin\setup.local.json -NonInteractive -Stage export -Yes
```
If it asks for model deployment names, enter the **real** deployment names from Foundry (for example `claude-sonnet-5-apim`), not the suggested defaults. Send the new `developer/claude-client-configuration.json` to developers.

### Monitoring
The setup deploys two Azure Monitor workbooks. Open the Log Analytics workspace > **Workbooks**:

| Workbook | Tabs and content | Defined in |
|---|---|---|
| **Claude usage — gateway view** | **Overview** (requests, tokens, developers, success rate), **People** (top developers by tokens, active developers per day), **Models & cost** (tokens and estimated cost per model), **Health** (status codes, denials, latency) | `infra/08-claude-usage-workbook.json`, deployed by `infra/09-workbook.bicep` when `options.workbook` is `true` |
| **Claude team governance** | Spend against each team's budget, and cost per developer within each team | `infra/23-team-governance-workbook.json`, deployed with `infra/22-team-governance.bicep` |

How it works: the gateway policy adds the caller's identity (`x-caller-oid`, `x-caller-upn`) and team to each request in the API Management logs, and the workbook queries group those logs by developer, team, model and status. Data appears 5–15 minutes after requests.

Reading the numbers:
- **Success rate** counts every request, including deliberate denials (401 without sign-in, 403 for blocked models or budgets). A low rate during testing is normal.
- **Estimated cost** uses the prices loaded from `snippets/15-load-pricing.py` and excludes cache writes (see the README, Known limitations). Reconcile with Azure Cost Management.
- Rows showing `anonymous` or a GUID are requests without a signed-in user (for example the 401 smoke test) or from before the policy was deployed.

**Changing a workbook:** you can select **Edit** in the portal and **Save**, but the next setup run overwrites the workbook. For lasting changes, use **Edit > Advanced editor**, copy the JSON into the matching file in `infra/`, and commit it; the next setup run then deploys your version.

### Add Grafana later
1. In `admin/setup.local.json`, set `options.grafana` to `true` and fill `grafanaName` and `grafanaLocation`. Leave `grafanaAdminPrincipalId` empty to make the signed-in user the Grafana admin, or set the admin's **user object ID in this tenant** (an app ID or app object ID does not work).
2. Run only the reporting stage:
```bash
az extension add -n amg
./admin/claude-gateway-setup.sh --config admin/setup.local.json --non-interactive --stage reporting --yes
```
```powershell
az extension add -n amg
.\admin\claude-gateway-setup.ps1 -ConfigPath admin\setup.local.json -NonInteractive -Stage reporting -Yes
```
Some dashboards use the hourly summary table; to create it, also set `options.summaryRule` to `true` before running the reporting stage.

---

## 5. Clean-up

> **Delete only what this deployment created.** Microsoft Entra ID is shared by the whole organization, and other teams may have apps or groups with similar names (for example "Claude Desktop - ..." or "Claude Team - ..."). Never delete by a name pattern; use the exact IDs and names below, and check each item before deleting it.

### 5.1 Collect the exact IDs (read-only)
From the repository folder used for the deployment:
```powershell
$cfg = Get-Content -Raw admin\setup.local.json | ConvertFrom-Json
"Resource group : $($cfg.resourceGroup)"
"Gateway app    : $($cfg.gatewayAudience)"
"Budget API app : $($cfg.budgetApiAudience)"
"Desktop app    : " + (Get-Content -Raw developer\claude-client-configuration.json | ConvertFrom-Json).gatewaySso.clientId
$cfg.teamGovernance.teams | ForEach-Object { "Team group     : $($_.groupDisplayName)" }
```
```bash
jq -r '"Resource group : \(.resourceGroup)\nGateway app    : \(.gatewayAudience)\nBudget API app : \(.budgetApiAudience)"' admin/setup.local.json
jq -r '"Desktop app    : \(.gatewaySso.clientId)"' developer/claude-client-configuration.json
jq -r '.teamGovernance.teams[] | "Team group     : \(.groupDisplayName)"' admin/setup.local.json
```
If `budgetApiAudience` is empty, find the app named exactly "Claude Budget API - &lt;prefix&gt;" under **App registrations > Owned applications**.

Check each app before deleting it:
```bash
az ad app show --id <app-id> --query "{name:displayName, appId:appId}" -o table
```
Check each team group and its members; delete it only if the members are the ones from your configuration and only one group has that name:
```bash
az ad group list --display-name "<exact group name>" --query "[].{name:displayName, id:id}" -o table
az ad group member list --group <group-id> --query "[].userPrincipalName" -o tsv
```

### 5.2 Delete
1. **The gateway resource group** (API Management, Function Apps, Redis, Cosmos DB, Event Hub, storage and, if it is there, the Log Analytics workspace with its usage data and workbooks):
   ```bash
   az group delete -n <resource-group> --yes --no-wait
   ```
   If the Log Analytics workspace is in a **different** resource group, also delete the pricing data collection rule (`dcr-claudeprice-...`) and the workbooks there, and the workspace if it was created only for the gateway.
2. **The three apps**, by their exact IDs from 5.1:
   ```bash
   az ad app delete --id <gateway-app-id>
   az ad app delete --id <desktop-app-id>
   az ad app delete --id <budget-api-app-id>
   ```
3. **The team groups**, by their IDs from 5.1, after checking the members:
   ```bash
   az ad group delete --group <group-id>
   ```
   Or in the portal: **Microsoft Entra ID > App registrations > Owned applications** (shows only apps you own) and **Groups > All groups**; open each item, check it, then **Delete**.
4. **Leave the Microsoft Foundry resource and its model deployments**, unless they were created only for this gateway.
5. A deleted API Management instance keeps its name reserved for 48 hours. To reuse the same name sooner:
   ```bash
   az apim deletedservice purge --service-name <apim-name> --location <region>
   ```
6. On the deployment machine, delete `admin/setup.local.json`, `admin/setup.rejected.json`, `developer/claude-client-configuration.json` and `logs/`; they contain environment details.

---

## 6. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `Invalid admin config` | An answer or setting breaks a rule | The script lists the failing rules under "Configuration rules that failed", with the values that caused them. In interactive mode the answers are saved to `admin/setup.rejected.json`. To check a file yourself: `jq -f admin/validate-config-check.jq admin/setup.local.json` (rules with `"ok": false` failed). Common cause: the same user in two teams. |
| `The system cannot find the file specified` (Windows) | A `<...>` placeholder was left in a command; Windows reads `<` as "read from a file" | Replace every placeholder, including the angle brackets (or set the values once, as in deployment guide step B1) |
| Script fails to start: "requires ... version 7" or `Unexpected token '??'` | Running in Windows PowerShell 5.1 or Command Prompt | Open PowerShell 7 (`pwsh`) |
| `uuidgen is required`, or `Invalid admin config` with correct answers, in Git Bash | Windows tools add hidden characters | Use Linux/WSL, or PowerShell 7 |
| `No module named 'azure'` | `pythonExecutable` points to a Python without the packages | Set it to the virtual environment's Python |
| `pythonExecutable ... is not a working Python 3` (PowerShell) | Microsoft Store placeholder | Install Python and use the venv path |
| `Set models.<family>: no unique deployment` | A model is missing or deployed twice | Exactly one deployment each of Opus, Sonnet, Haiku |
| `The extension quota is not installed` | Missing Azure CLI extension | `az extension add -n quota` |
| `MissingRegistrationForResourceProvider` | Provider not registered | Register the providers (deployment guide, B4) |
| `EP1 limit must support at least two always-ready instances` | Not enough EP1 quota | Request quota or choose another region |
| `Review PRICES ... pricesReviewed=true` | Safety stop | Review the prices, then set `options.pricesReviewed` to `true` |
| `Wrong Azure tenant` | Azure CLI signed in to another tenant | `az login --tenant <tenant-id>` |
| AADSTS `530033` at sign-in | Conditional Access requires a managed device | Sign in with the browser from a managed device, not a device code |
| `Price loading failed after 3 attempts` | Role assignments still propagating, or Azure CLI too slow to answer (Python waits about 10 seconds; seen on Windows) | The setup already retries. Wait a few minutes, run `az account get-access-token --scope https://redis.azure.com/.default -o none`, then re-run with the same names |
| `AzureCliCredential: Failed to invoke the Azure CLI` | Azure CLI took too long to return a token | As above |
| `Python credential resolved to a different tenant than tenantId` | Python used a cached Windows/Office account from another tenant | Current scripts set `AZURE_TOKEN_CREDENTIALS=AzureCliCredential` automatically. With an older script, run `$env:AZURE_TOKEN_CREDENTIALS = "AzureCliCredential"` (PowerShell) or `export AZURE_TOKEN_CREDENTIALS=AzureCliCredential` (Bash), then re-run |
| `ExpiredAuthenticationToken` | The computer slept or the sign-in expired during a long run | `az login --tenant <tenant-id>`, `az account set --subscription <subscription-id>`, then re-run the same command |
| Window shows no output; the log has no new lines | Windows paused the program (text selected in the window), or another window holds the log file open (`Get-Content -Wait`) | Press **Esc**. If nothing happens, press Ctrl+C, close other windows reading the log, and re-run with a new `-LogFile` name |
| `Log Analytics workspace not found` | Wrong subscription, resource group or name in `workspaceResourceId` | Correct it in `admin/setup.local.json` and re-run preflight |
| 403 `team-model-policy` for an allowed model | The gateway does not know a deployment name (added after the last deployment, or an older script was used) | Run the governance script with `--yes` / `-Yes` again |
| `PolicyDeployment_...` entries in the deployment list | Your organization's Azure Policy | Not part of this setup; no action |
| Deployment stopped (closed terminal, lost session) | The run was interrupted | Re-run the same command; existing resources are reused |
| "Need admin approval – Microsoft Azure CLI" (developers) | Azure CLI not authorized on the gateway API | Section 1 |
| Desktop `invalid_client` | Wrong Scopes, Client ID or Issuer URL in Desktop | Developer guide, Part 2 |
| Gateway returns 401 to a signed-in user | No `Claude.User` role, or wrong token type | Check team membership and role assignments; Desktop must use **Access token** |
| 403 `identity` for a user who should have access | `enforce` mode and the user is in no team, or in two teams | Put the user in exactly one team; they sign in again |
| 403 `team-model-policy` | Model not in the team's `allowedModels` | Add the model to the team, or use an allowed model |
