# Claude on Azure gateway: operations guide

Day-2 tasks for administrators after the deployment. Commands are shown for Linux (Bash) and Windows (PowerShell 7); run them from the repository folder with the same `admin/setup.local.json` used for the deployment.

> Keep `admin/setup.local.json` safe and **do not commit it** to source control. It holds your tenant, subscription, resource names and team member names. The same applies to `developer/claude-client-configuration.json` and the `logs` folder.

---

## 1. Access and consent

### Allow Azure CLI to request gateway tokens
Claude Code CLI and the VS Code extension get their gateway token through Azure CLI. In tenants that block user consent, developers otherwise see **"Need admin approval – Microsoft Azure CLI"**. Choose one of these options:

**Option A: authorized client application (set by the gateway app owner)**
1. Azure portal > **Microsoft Entra ID** > **App registrations** > **All applications** > the gateway app ("Claude Gateway - &lt;APIM name&gt;").
2. **Expose an API** > **Authorized client applications** > **Add a client application**.
3. Client ID: `04b07795-8ddb-461a-bbee-02f9e1bf7b46` (Microsoft Azure CLI; the same ID in every tenant).
4. Select the `access_as_user` scope > **Add application**.

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
Open the Log Analytics workspace > **Workbooks**:
- **Claude team governance**: spend against the team budget, and cost per developer within each team.
- The usage workbook deployed by `09-workbook`.

### Add Grafana later
1. In `admin/setup.local.json`, set `options.grafana` to `true` and fill `grafanaName`, `grafanaLocation` and `grafanaAdminPrincipalId` (the admin's **user object ID in this tenant**; an app ID or app object ID does not work).
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

1. Delete the gateway resource group (APIM, Functions, Redis, Cosmos DB and Grafana are billed per hour):
   ```bash
   az group delete -n <resource-group> --yes --no-wait
   ```
2. If the Log Analytics workspace is in a **different** resource group, also delete the pricing data collection rule (`dcr-claudeprice-...`) and the workbooks there (and the workspace, if it was created only for the gateway). If the workspace is in the gateway resource group, step 1 removes it, including its usage data.
3. Delete the Entra objects: the gateway app, "Claude Desktop - &lt;APIM name&gt;", "Claude Budget API - &lt;prefix&gt;", and the "Claude Team - ..." groups:
   ```bash
   az ad app delete --id <app-id>
   az ad group delete --group "Claude Team - <team name>"
   ```
4. A deleted API Management instance is kept for 48 hours. To reuse the same name sooner:
   ```bash
   az apim deletedservice purge --service-name <apim-name> --location <region>
   ```

---

## 6. Troubleshooting

| Message | Cause | Fix |
|---|---|---|
| `Invalid admin config` | An answer or setting breaks a rule | Check the configuration with `jq -f admin/validate-config-check.jq admin/setup.local.json`; each rule shows `true` or `false`. With PowerShell, rejected interactive answers are also saved to `admin/setup.rejected.json`. |
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
| Price loading or permission errors on the first run | Role assignments are still propagating | Wait a few minutes and re-run with the same names |
| Deployment stopped (closed terminal, lost session) | The run was interrupted | Re-run the same command; existing resources are reused |
| "Need admin approval – Microsoft Azure CLI" (developers) | Azure CLI not authorized on the gateway API | Section 1 |
| Desktop `invalid_client` | Wrong Scopes, Client ID or Issuer URL in Desktop | Developer guide, Part 2 |
| Gateway returns 401 to a signed-in user | No `Claude.User` role, or wrong token type | Check team membership and role assignments; Desktop must use **Access token** |
| 403 `identity` for a user who should have access | `enforce` mode and the user is in no team, or in two teams | Put the user in exactly one team; they sign in again |
| 403 `team-model-policy` | Model not in the team's `allowedModels` | Add the model to the team, or use an allowed model |
