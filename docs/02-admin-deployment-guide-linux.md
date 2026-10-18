# Claude on Azure gateway: admin deployment guide (Linux / Bash)

This guide deploys the gateway from a Linux shell: Ubuntu, WSL on Windows, a Linux VM, or Azure Cloud Shell with a storage account mounted.
For Windows with PowerShell, see `03-admin-deployment-guide-windows.md`.

Complete `01-prerequisites-checklist.md` first.

**Time:** about 15 minutes of preparation, then 45–60 minutes for the deployment (most of it is creating API Management).

Each step starts with **Why**, a short explanation of what the step is for.

> **Do not use Git Bash on Windows.** The Windows versions of `az` and `jq` add hidden carriage-return characters that break the scripts.
>
> **Placeholders:** replace every `<...>` value, including the angle brackets.

---

## Part A: Prepare the machine (one time)

### A1. Install the tools
**Why:** the scripts call these tools.
- **Azure CLI** signs in and creates the Azure and Entra resources.
- **jq** reads and checks the JSON configuration; **uuidgen** creates IDs for the app roles.
- **Python** (with `venv`) loads the model prices into Log Analytics and Redis.
- **Azure Functions Core Tools** (`func`) publishes the code of the two Function Apps (budget API and usage processor).
- **Bicep** compiles the Azure templates; the **quota** extension checks Function plan capacity.
- **tmux** keeps the deployment running if your terminal disconnects.

```bash
sudo apt update && sudo apt install -y git jq uuid-runtime python3-venv tmux curl
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az bicep install
az extension add -n quota

# Azure Functions Core Tools v4
curl -sL https://packages.microsoft.com/keys/microsoft.asc | sudo gpg --dearmor -o /usr/share/keyrings/microsoft.gpg
echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/microsoft-ubuntu-$(lsb_release -cs)-prod $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/dotnetdev.list
sudo apt update && sudo apt install -y azure-functions-core-tools-4
```
**On WSL:** check that `which az jq func` all show `/usr/bin/...`. A path starting with `/mnt/c/` is the Windows version, which adds hidden characters; install the Linux version as above.

### A2. Get the repository and the Python environment
**Why:** the repository contains the scripts, the Azure templates and the Function code. The `logs` folder keeps a record of the deployment. A Python virtual environment keeps the packages the scripts need separate from the system Python.

Clone **inside Linux**. Do not copy `.sh` files from a Windows folder; Windows line endings break them.
Use the latest **release** (tested version) rather than the newest changes: check **Releases** on the repository page and use that tag in `--branch` (this guide was written for `v1.0.2`). `git clone` creates a folder named `claude-foundry-apim-gateway` in your home folder; if a folder with that name already exists there, clone into another folder.
```bash
cd ~
git clone --branch v1.0.2 https://github.com/umaranit/claude-foundry-apim-gateway.git
cd claude-foundry-apim-gateway          # the folder git clone created
chmod +x admin/*.sh && mkdir -p logs
python3 -m venv ~/claude-venv
source ~/claude-venv/bin/activate
pip install azure-identity azure-monitor-ingestion requests redis
echo "$HOME/claude-venv/bin/python"
```
The last line shows the **Python path**; step C3 saves it in the configuration. Run all later commands from the repository folder.

---

## Part B: Prepare the subscription

### B1. Set your values and sign in
**Why:** every later command runs against this tenant and subscription. Setting the values once here means you do not edit placeholders in each command, which avoids typing mistakes.

Fill in your values (keep the quotes), then run the block. `export` lets the setup script offer them as default answers in preflight (C2).
```bash
export TENANT="<tenant-id>"
export SUB="<subscription-id>"
export REGION="<region>"                    # for example centralus
export RG="<resource-group>"                # gateway resource group
export WS="<workspace-name>"                # Log Analytics workspace
export FOUNDRY_RG="<foundry-resource-group>"
export FOUNDRY="<foundry-resource-name>"
export APIM="<apim-name>"                   # globally unique
export PREFIX="<prefix>"                    # 3-11 lowercase letters or digits

az login --tenant "$TENANT"
az account set --subscription "$SUB"
az account show --query "{tenant:tenantId, subscription:name}" -o table
```
These values last only in this terminal. If you open a new one (or a new `tmux` window), run the variable lines again.
If Conditional Access requires a managed device, use the browser sign-in (not `--use-device-code`). On WSL, if the browser does not open, copy the sign-in link from the terminal into your Windows browser.

### B2. Create the resource group and Log Analytics workspace
**Why:** all gateway resources go into one resource group, so they are easy to find, secure and delete. The Log Analytics workspace stores the gateway logs, the usage per user and team, and the model prices; the workbooks read from it.

Skip this step if they already exist (checklist items 5 and 6).
```bash
az group create -n "$RG" -l "$REGION" -o table
export WS_ID=$(az monitor log-analytics workspace create -g "$RG" -n "$WS" -l "$REGION" --query id -o tsv)
echo "$WS_ID"
```
The last line shows the **workspace resource ID**. Preflight (C2) asks for it. If the workspace already exists:
```bash
export WS_ID=$(az monitor log-analytics workspace show -g "$RG" -n "$WS" --query id -o tsv); echo "$WS_ID"
```
Use the same region for the workspace and the gateway unless your organization requires otherwise.

### B3. Check the Foundry model deployments
**Why:** the gateway sends requests to these deployments. The setup finds the Opus, Sonnet and Haiku deployments by model name; if a model is missing or deployed twice, it cannot tell which one to use.

```bash
az cognitiveservices account deployment list -g "$FOUNDRY_RG" -n "$FOUNDRY" \
  --query "[].{deployment:name, model:properties.model.name}" -o table
```
There must be **exactly one** deployment of each: Opus, Sonnet and Haiku. Other models (for example GPT models) do not matter.

### B4. Register resource providers
**Why:** an Azure service must be enabled ("registered") in a subscription before resources of that type can be created. New subscriptions often have some of these turned off, and the setup does not turn them on by itself.

```bash
PROVIDERS="Microsoft.Quota Microsoft.ApiManagement Microsoft.Web Microsoft.Cache Microsoft.DocumentDB Microsoft.EventHub Microsoft.Insights Microsoft.OperationalInsights Microsoft.Storage Microsoft.Dashboard"
for p in $PROVIDERS; do az provider register --namespace $p; done
for p in $PROVIDERS; do echo "$p: $(az provider show -n $p --query registrationState -o tsv)"; done
```
Repeat the second loop until every provider shows `Registered` (usually 1–3 minutes).

### B5. Check EP1 quota
**Why:** the budget API and usage processor run on an Elastic Premium (EP1) Function plan with 2 always-ready instances, so they answer quickly without start-up delays. If the subscription does not have 2 free EP1 instances in the region, the deployment fails partway through.

```bash
SCOPE="/subscriptions/$SUB/providers/Microsoft.Web/locations/$REGION"
az quota show --resource-name EP1 --scope "$SCOPE" --query "properties.limit.value" -o tsv
az quota usage show --resource-name EP1 --scope "$SCOPE" --query "properties.usages.value" -o tsv
```
The first number (limit) minus the second (usage) must be **2 or more**. If not, request more quota or choose another region.

---

## Part C: Deploy

### C1. Create the gateway app with all roles
**Why:** this Entra app registration represents the gateway API. Users get their sign-in token **for this app**, and its roles decide who may use the gateway (`Claude.User`), which per-user tier applies (`Claude.Tier.*`), and who is blocked (`Claude.Suspended`). Creating it first makes sure all four roles exist; the setup in C2 reuses it by name.

```bash
./admin/create-claude-gateway-app.sh --tenant-id "$TENANT" --display-name "Claude Gateway - $APIM" --dry-run
./admin/create-claude-gateway-app.sh --tenant-id "$TENANT" --display-name "Claude Gateway - $APIM" --yes
```
The first command shows the plan only. The second creates the app; its output lists the roles `Claude.User`, `Claude.Tier.Pro`, `Claude.Tier.Basic` and `Claude.Suspended`.

### C2. Preflight (asks questions, saves the answers, deploys nothing)
**Why:** collects all settings and saves them to `admin/setup.local.json`, so the deployment can be repeated with exactly the same values. It also checks, before anything is deployed, that you can reach Azure and Entra, that the models and workspace exist, that there is enough quota, and that the templates compile. It updates the gateway app from C1 (it does not create Azure resources).

```bash
./admin/claude-gateway-setup.sh --interactive --stage preflight
```

| Question | Answer |
|---|---|
| Subscription ID, Tenant ID | Press Enter (from B1, or your current Azure CLI sign-in) |
| Publisher name | Press Enter, or your team name |
| Resource group name | Press Enter (`$RG` from B1) |
| Foundry resource group name | Press Enter (`$FOUNDRY_RG`) |
| APIM name | Press Enter (`$APIM`) |
| APIM location | Press Enter (`$REGION`; also used for the budget platform) |
| Workspace location | Press Enter (`$REGION`), or the existing workspace's region |
| Workbook location | Press Enter (`$REGION`) |
| Publisher email | Press Enter (your sign-in), or the admin team's email |
| Gateway service principal name | Press Enter: the default is the C1 name, "Claude Gateway - `$APIM`" |
| Log Analytics workspace resource ID | Press Enter (`$WS_ID` from B2) |
| Foundry resource name | Press Enter (`$FOUNDRY`) |
| Resource name prefix | Press Enter (`$PREFIX`; 3–11 lowercase letters or digits, used in the names of the budget platform resources) |
| Configure team governance now? | `yes`, then the team details from the checklist. Each person may be in only one team. The team governance mode is `enforce` by default (see C3 to change it). |

Check each default in `[...]` before pressing Enter; type a value to replace it. Team member sign-in names are entered comma-separated, without spaces.

Expected result:
```
Saved interactive configuration to .../admin/setup.local.json.
Preflight passed; ... no Azure resource deployments were made.
```

**If preflight stops with an error:** your answers are already saved, and the next interactive run offers them as defaults in `[...]`. Check every default, or correct the saved file and rerun preflight without the questions. For example, to correct the workspace ID:
```bash
jq --arg w "<correct-workspace-resource-id>" '.workspaceResourceId=$w' admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
./admin/claude-gateway-setup.sh --config admin/setup.local.json --non-interactive --stage preflight
```

### C3. Review the saved configuration
**Why:** this is the last check before resources are created. `pricesReviewed` is a safety switch: the deployment stops until you confirm that the model prices in `snippets/15-load-pricing.py` match your Azure agreement, because budgets are calculated from them. The Python path tells the scripts which Python has the packages from A2. The validation at the end catches mistakes from manual edits.

**1. Set the Python path and confirm that the prices are reviewed** (required):
```bash
jq --arg p "$HOME/claude-venv/bin/python" '.pythonExecutable=$p | .options.pricesReviewed=true' \
  admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
```

**2. Only if you want to start in `observe` mode** (skip this to keep the default, `enforce`):
```bash
jq '.teamGovernance.mode="observe"' admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
```
In `enforce` mode every user must be in exactly one team, and each team can use only its allowed models.

**3. Only if you want Grafana** (skip this otherwise). Azure Managed Grafana adds dashboards on top of the workbooks; it is billed per hour plus per active user.
```bash
az extension add -n amg
GRAFANA_NAME="$(jq -r .namePrefix admin/setup.local.json)-grafana"
jq --arg n "$GRAFANA_NAME" --arg l "$REGION" '.options.grafana=true | .grafanaName=$n | .grafanaLocation=$l' \
  admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
```
- **Grafana name:** your prefix plus `-grafana` (2–23 letters, digits or hyphens; start with a letter).
- **Grafana admin:** left empty, the setup makes **the signed-in user** (you) the Grafana admin. To choose someone else, set their **user object ID in this tenant** (Microsoft Entra ID > Users > person > Overview > Object ID; not an app ID or tenant ID):
  ```bash
  ADMIN_OID=$(az ad user show --id <sign-in-name> --query id -o tsv)
  jq --arg a "$ADMIN_OID" '.grafanaAdminPrincipalId=$a' admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
  ```

**4. Check the settings and validate** (required). Three short checks. Nothing is changed by them.

**4a. The deployment settings.** Run:
```bash
jq '{resourceGroup, apimName, namePrefix, workspaceResourceId, gatewayAudience, pythonExecutable, mode: .teamGovernance.mode, grafana: .options.grafana, pricesReviewed: .options.pricesReviewed}' admin/setup.local.json
```
Compare each line with what you expect:

| Setting | It should be | If it is wrong |
|---|---|---|
| `resourceGroup` | The gateway resource group from B1/B2 | Run preflight (C2) again, or correct it in the file |
| `apimName` | The APIM name you chose | As above |
| `namePrefix` | Your 3–11 character prefix | As above |
| `workspaceResourceId` | Contains **your** subscription, resource group and workspace name (from B2). A common mistake is an ID copied from another deployment. | Correct it (see "If preflight stops with an error" in C2) |
| `gatewayAudience` | The `gatewayAudience` (app ID) printed in C1 | Check that you pressed Enter at the gateway service principal question in C2 |
| `pythonExecutable` | The Python from A2 (or `python`) | Correct it in the file |
| `mode` | `enforce` (default), or `observe` if you chose part 2 | Run part 2 again with the value you want |
| `grafana` | `false`, or `true` if you chose part 3 | Set `.options.grafana=false` with the same command pattern as part 2 |
| `pricesReviewed` | `true` | Run part 1 |

**4b. The teams.** Run:
```bash
jq '.teamGovernance.teams[] | {id, profile, defaultUserTier, allowedModels, members}' admin/setup.local.json
```
For each team, check: the members are the right people (sign-in names), **no person appears in two teams**, the profile (`regular`/`power`) and default tier (`pro`/`basic`/`lite`) are what the business owner asked for, and `allowedModels` lists the models the team may use. In `enforce` mode, anyone not listed in a team cannot use the gateway.

**4c. The automatic check.** Run:
```bash
jq -e -f admin/validate-config.jq admin/setup.local.json > /dev/null && echo "Config OK" || echo "Config INVALID"
```
- `Config OK`: continue to the deployment.
- `Config INVALID`: list the rule that failed (rules with `"ok": false`), fix it, and run 4c again:
  ```bash
  jq -f admin/validate-config-check.jq admin/setup.local.json
  ```

**Decisions to confirm with the business owner before deploying.** These affect users and cost:
1. **Model prices.** Spend is calculated from the prices in `snippets/15-load-pricing.py`. If you have negotiated prices, update the file first. To view them: `grep -n -A 20 "PRICES" snippets/15-load-pricing.py`
2. **Budgets and limits.** Monthly user-tier budgets and team budgets. Change them now in the file, or later (operations guide, section 3). To view them: `jq '{userTiers: .tiersConfig, teamProfiles: .teamGovernance.profiles}' admin/setup.local.json`
3. **Budgets are guardrails, not exact bills.** Cache-write tokens are not counted, users can go slightly over a limit before it applies, and requests are allowed if the budget service is unavailable. Reconcile with Azure Cost Management.
4. **`enforce` or `observe`.** `enforce` blocks from the first request; `observe` only records, for a trial period.

### C4. Deploy (45–60 minutes)
**Why:** creates everything in the right order, because later parts need outputs from earlier ones:
1. API Management (first without its policy, to get its managed identity)
2. Tier and pricing data in Log Analytics
3. The budget platform: Event Hub, Redis, Cosmos DB, storage and the two Function Apps
4. Loads the model prices and publishes the Function code
5. Team groups, members and roles in Entra, and the team settings in the gateway
6. The final APIM policy (sign-in check, limits, budget check, call to Foundry)
7. The client settings file for developers, and the workbook

Run inside `tmux` so a dropped connection does not stop the deployment. Keep the machine awake.
```bash
tmux new -s claude
source ~/claude-venv/bin/activate
cd ~/claude-foundry-apim-gateway
./admin/claude-gateway-setup.sh --config admin/setup.local.json --non-interactive --yes \
  --debug --log-file logs/claude-gateway-setup.log
```
If the terminal disconnects, reconnect and run `tmux attach -t claude`.
Expected last line: `Selected steps completed. ...`

**If it stops:** read the end of the log, fix the cause (see the operations guide, Troubleshooting), sign in again if needed (for example after the machine slept: `ExpiredAuthenticationToken`), and run the **same command** again. Existing resources are reused, so a rerun continues where it stopped.
```bash
tail -30 logs/claude-gateway-setup.log
az login --tenant "$TENANT" && az account set --subscription "$SUB"
```

---

## Part D: Verify

### D1. Deployments and Entra objects
**Why:** confirms that each part was deployed, and that the Entra groups, members and roles match the configuration.

```bash
az deployment group list -g "$RG" --query "[].{name:name, state:properties.provisioningState}" -o table
./admin/setup-teams-governance-claude-gateway.sh --config admin/setup.local.json --check
az ad app show --id "$(jq -r .gatewayAudience admin/setup.local.json)" --query "appRoles[].value" -o tsv
```
- `04-apim-gateway`, `14-claude-tiers`, `16-budget-platform`, `22-team-governance` and `09-workbook` show **Succeeded**. A failed `Failure-Anomalies-Alert-Rule` deployment is added by Azure and can be ignored. `PolicyDeployment_...` entries come from your organization's Azure Policy, not from this setup.
- The governance check ends with `Team governance reconciliation complete`.
- The roles include `Claude.User`, the tier roles and the team and profile roles.

### D2. Check that developers can sign in with Azure CLI
**Why:** Claude Code (CLI and VS Code) gets its gateway token through Azure CLI. Many organizations do not let users approve this themselves ("Need admin approval"). The setup therefore pre-authorizes Azure CLI on the gateway API, the same way it does for Claude Desktop.

Check it:
```bash
az ad app show --id "$(jq -r .gatewayAudience admin/setup.local.json)" --query "api.preAuthorizedApplications[].appId" -o tsv
```
The list must contain `04b07795-8ddb-461a-bbee-02f9e1bf7b46` (Microsoft Azure CLI, the same ID in every tenant) and the Claude Desktop client ID. If Azure CLI is missing, add it by hand: operations guide, "Allow Azure CLI to request gateway tokens".

If your organization prefers admin consent instead, set `options.preAuthorizeAzureCli` to `false` in C3 before deploying, and have an Entra admin grant consent.

### D3. End-to-end test as a user
**Why:** proves the whole path works: sign-in, role check, API Management, budget check and Foundry. The first test call has no token and must be rejected (401); the second, with your token, must succeed (200).

Use an account that is in a team (it then has the `Claude.User` role):
```bash
bash developer/setup-claude-workstation.sh --config developer/claude-client-configuration.json --dry-run
bash developer/setup-claude-workstation.sh --config developer/claude-client-configuration.json --login --test-only
```
Expected: `Smoke tests passed: unauthenticated 401; authenticated inference 200.`
`--test-only` changes no settings and makes one small billable request.

### D4. Team governance checks (enforce mode)
**Why:** proves that the `enforce` rules block what they should, before your users rely on them.

Run these with real users after the smoke test (each makes at most one small billable request):

| Test | Expected |
|---|---|
| Team member calls an allowed model | Success (200) |
| Team member calls a model **not** in the team's `allowedModels` | 403 with header `x-claude-denied-by: team-model-policy` |
| User with `Claude.User` but in no team | 403 with header `x-claude-denied-by: identity` |

Each team's allowed models also cover their Foundry deployments, whatever the deployment names are (for example `claude-sonnet-5-apim` counts as `claude-sonnet-5`). The setup looks the names up each time it deploys the team settings.

To see the result, call the gateway with a token (replace the model name with a deployment name from B3):
```bash
CFG=developer/claude-client-configuration.json
RES=$(jq -r '.gatewaySso.scopes' $CFG | tr ' ' '\n' | grep '^api://' | sed 's#/[^/]*$##')
TOK=$(az account get-access-token --resource "$RES" --query accessToken -o tsv)
curl -s -o /dev/null -D - "$(jq -r .gatewayUrl $CFG)/v1/messages" \
  -H "content-type: application/json" -H "anthropic-version: 2023-06-01" -H "x-api-key: $TOK" -H "Authorization: Bearer unused" \
  -d '{"model":"<model-deployment-name>","max_tokens":16,"messages":[{"role":"user","content":"Reply with READY"}]}' \
  | grep -i -E "^HTTP|x-claude-denied-by"
```

### D5. Usage tracking
**Why:** proves that usage events reach Log Analytics and that cost is attributed to the right user and team, which the budgets depend on.

After 5–15 minutes, open the Log Analytics workspace > **Workbooks** > **Claude team governance**. The test calls appear under the team and the user, with tokens and estimated cost.

### D6. Hand over to developers
**Why:** developers need only these files; they contain no secrets and no Azure resource details.

- `developer/claude-client-configuration.json`
- `developer/setup-claude-workstation.sh` and `developer/setup-claude-workstation.ps1`
- `04-developer-onboarding-guide.md`

---

## Next steps

Adding teams, changing budgets, re-exporting settings, Grafana and clean-up are covered in `05-operations-guide.md`, along with troubleshooting.
