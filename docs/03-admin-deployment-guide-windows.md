# Claude on Azure gateway: admin deployment guide (Windows / PowerShell)

This guide deploys the gateway from Windows with **PowerShell 7.3 or newer** (`pwsh`).
For Linux, see `02-admin-deployment-guide-linux.md`.

Complete `01-prerequisites-checklist.md` first.

**Time:** about 15 minutes of preparation, then 45–60 minutes for the deployment (most of it is creating API Management).

Each step starts with **Why**, a short explanation of what the step is for.

> **Use PowerShell 7** (`pwsh`). Command Prompt and Windows PowerShell 5.1 cannot run the scripts. Do not run the `.sh` scripts in Git Bash.
>
> **Placeholders:** replace every `<...>` value, including the angle brackets. A leftover `<` makes Windows report *"The system cannot find the file specified"*.

---

## Part A: Prepare the machine (one time)

### A1. Install the tools
**Why:** the scripts call these tools.
- **PowerShell 7** runs the setup scripts. They use features that Windows PowerShell 5.1 does not have.
- **Azure CLI** signs in and creates the Azure and Entra resources.
- **jq** reads and checks the JSON configuration.
- **Python** loads the model prices into Log Analytics and Redis.
- **Azure Functions Core Tools** (`func`) publishes the code of the two Function Apps (budget API and usage processor).
- **Bicep** compiles the Azure templates; the **quota** extension checks Function plan capacity.

In any PowerShell window (a tool that is already installed is skipped or upgraded):
```powershell
winget install Microsoft.PowerShell
winget install jqlang.jq
winget install Microsoft.AzureCLI
winget install Python.Python.3.13
winget install Microsoft.Azure.FunctionsCoreTools
```
Close the window and open **PowerShell 7** (Windows key + R, type `pwsh`, press Enter). Then:
```powershell
$PSVersionTable.PSVersion          # Major must be 7 (7.3 or higher). If it shows 5, type pwsh
jq --version
python --version                   # Python 3.x; if the Microsoft Store opens, Python is not installed
func --version                     # 4.x (a copy installed earlier through npm is also fine)
az bicep install
az extension add -n quota
```

### A2. Get the repository and the Python environment
**Why:** the repository contains the scripts, the Azure templates and the Function code. The `logs` folder keeps a record of the deployment. A Python virtual environment keeps the packages the scripts need separate from any other Python on the machine.

```powershell
cd C:\<work-folder>
git clone https://github.com/umaranit/claude-foundry-apim-gateway.git
cd claude-foundry-apim-gateway
New-Item -ItemType Directory -Force logs | Out-Null
python -m venv $HOME\claude-venv-win
& $HOME\claude-venv-win\Scripts\python.exe -m pip install azure-identity azure-monitor-ingestion requests redis
```
If PowerShell reports that a script "is not digitally signed", unblock the repository scripts (subject to your organization's script policy):
```powershell
Get-ChildItem admin\*.ps1, developer\*.ps1 | Unblock-File
```

---

## Part B: Prepare the subscription

### B1. Set your values and sign in
**Why:** every later command runs against this tenant and subscription. Setting the values once here means you do not edit placeholders in each command, which avoids typing mistakes.

Fill in your values (keep the quotes), then run the block:
```powershell
$Tenant    = "<tenant-id>"
$Sub       = "<subscription-id>"
$Region    = "<region>"                    # for example centralus
$Rg        = "<resource-group>"            # gateway resource group
$Ws        = "<workspace-name>"            # Log Analytics workspace
$FoundryRg = "<foundry-resource-group>"
$Foundry   = "<foundry-resource-name>"
$Apim      = "<apim-name>"                 # globally unique

az login --tenant $Tenant
az account set --subscription $Sub
az account show --query "{tenant:tenantId, subscription:name}" -o table
```
These values last only in this window. If you open a new window, run the `$...` lines again.

### B2. Create the resource group and Log Analytics workspace
**Why:** all gateway resources go into one resource group, so they are easy to find, secure and delete. The Log Analytics workspace stores the gateway logs, the usage per user and team, and the model prices; the workbooks read from it.

Skip this step if they already exist (checklist items 5 and 6).
```powershell
az group create -n $Rg -l $Region -o table
$WsId = az monitor log-analytics workspace create -g $Rg -n $Ws -l $Region --query id -o tsv
$WsId
```
The last line shows the **workspace resource ID**. Preflight (C3) asks for it. If the workspace already exists:
```powershell
$WsId = az monitor log-analytics workspace show -g $Rg -n $Ws --query id -o tsv
$WsId
```
Use the same region for the workspace and the gateway unless your organization requires otherwise.

### B3. Check the Foundry model deployments
**Why:** the gateway sends requests to these deployments. The setup finds the Opus, Sonnet and Haiku deployments by model name; if a model is missing or deployed twice, it cannot tell which one to use.

```powershell
az cognitiveservices account deployment list -g $FoundryRg -n $Foundry --query "[].{deployment:name, model:properties.model.name}" -o table
```
There must be **exactly one** deployment of each: Opus, Sonnet and Haiku. Other models (for example GPT models) do not matter.

### B4. Register resource providers
**Why:** an Azure service must be enabled ("registered") in a subscription before resources of that type can be created. New subscriptions often have some of these turned off, and the setup does not turn them on by itself.

```powershell
$Providers = 'Microsoft.Quota','Microsoft.ApiManagement','Microsoft.Web','Microsoft.Cache','Microsoft.DocumentDB','Microsoft.EventHub','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Storage','Microsoft.Dashboard'
foreach ($p in $Providers) { az provider register --namespace $p }
foreach ($p in $Providers) { "{0,-32} {1}" -f $p, (az provider show -n $p --query registrationState -o tsv) }
```
Repeat the second loop until every provider shows `Registered` (usually 1–3 minutes).

### B5. Check EP1 quota
**Why:** the budget API and usage processor run on an Elastic Premium (EP1) Function plan with 2 always-ready instances, so they answer quickly without start-up delays. If the subscription does not have 2 free EP1 instances in the region, the deployment fails partway through.

```powershell
$Scope = "/subscriptions/$Sub/providers/Microsoft.Web/locations/$Region"
az quota show --resource-name EP1 --scope $Scope --query "properties.limit.value" -o tsv
az quota usage show --resource-name EP1 --scope $Scope --query "properties.usages.value" -o tsv
```
The first number (limit) minus the second (usage) must be **2 or more**. If not, request more quota or choose another region.

---

## Part C: Deploy

### C1. Create the gateway app with all roles
**Why:** this Entra app registration represents the gateway API. Users get their sign-in token **for this app**, and its roles decide who may use the gateway (`Claude.User`), which per-user tier applies (`Claude.Tier.*`), and who is blocked (`Claude.Suspended`). Creating it first makes sure all four roles exist; the setup in C3 reuses it by name.

```powershell
.\admin\create-claude-gateway-app.ps1 -TenantId $Tenant -DisplayName "Claude Gateway - $Apim" -DryRun
.\admin\create-claude-gateway-app.ps1 -TenantId $Tenant -DisplayName "Claude Gateway - $Apim" -Yes
```
The first command shows the plan only. The second creates the app; its output lists the roles `Claude.User`, `Claude.Tier.Pro`, `Claude.Tier.Basic` and `Claude.Suspended`.

### C2. Optional: dry run (no Azure calls, nothing saved)
**Why:** checks your answers and their format offline, before anything touches Azure.

```powershell
.\admin\claude-gateway-setup.ps1 -Interactive -DryRun
```
Expected: `DRY RUN: configuration validated.`

### C3. Preflight (asks questions, saves the answers, deploys nothing)
**Why:** collects all settings and saves them to `admin\setup.local.json`, so the deployment can be repeated with exactly the same values. It also checks, before anything is deployed, that you can reach Azure and Entra, that the models and workspace exist, that there is enough quota, and that the templates compile. It updates the gateway app from C1 (it does not create Azure resources).

```powershell
.\admin\claude-gateway-setup.ps1 -Interactive -Stage preflight -Debug -LogFile logs\preflight.log
```

| Question | Answer |
|---|---|
| Subscription ID, Tenant ID | The values of `$Sub` and `$Tenant` from B1 |
| Publisher name | Press Enter, or your team name |
| Gateway resource group name | `$Rg` |
| Foundry resource group name | `$FoundryRg` |
| APIM name | `$Apim` |
| APIM location | `$Region` (also used for the budget platform) |
| Workspace location | The workspace's region (`$Region` if created in B2) |
| Workbook location | `$Region` |
| Publisher email | Admin email |
| Gateway service principal name | Press Enter: the default is the C1 name, "Claude Gateway - `$Apim`" |
| Log Analytics workspace resource ID | The workspace resource ID shown in B2 (copy it from B2's output) |
| Foundry resource name | `$Foundry` |
| Resource name prefix | 3–11 lowercase letters or digits (used in the names of the budget platform resources) |
| Python executable | `C:\Users\<you>\claude-venv-win\Scripts\python.exe` |
| Configure team governance now? | `yes`, then the team details from the checklist. Each person may be in only one team. The team governance mode is `enforce` by default (see C4 to change it). |

Team member sign-in names are entered comma-separated, without spaces. If an answer has the wrong format (for example the prefix or the workspace ID), the script asks again.

Expected result:
```
Saved interactive configuration to ...\admin\setup.local.json.
Preflight passed; ... no Azure resource deployments were made.
```
Yellow `A new Bicep release is available` warnings are harmless (`az bicep upgrade` removes them).

**If preflight stops with an error:** your answers are already saved, and the next interactive run offers them as defaults in `[...]`. Check every default, or correct the saved file and rerun preflight without the questions. For example, to correct the workspace ID:
```powershell
jq --arg w "<correct-workspace-resource-id>" '.workspaceResourceId=$w' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
.\admin\claude-gateway-setup.ps1 -ConfigPath admin\setup.local.json -NonInteractive -Stage preflight -Debug -LogFile logs\preflight.log
```

### C4. Review the saved configuration
**Why:** this is the last check before resources are created. `pricesReviewed` is a safety switch: the deployment stops until you confirm that the model prices in `snippets\15-load-pricing.py` match your Azure agreement, because budgets are calculated from them. The validation at the end catches mistakes from manual edits.

**1. Confirm that the prices are reviewed** (required):
```powershell
jq '.options.pricesReviewed=true' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
```

**2. Only if you want to start in `observe` mode** (skip this to keep the default, `enforce`):
```powershell
jq '.teamGovernance.mode="observe"' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
```
In `enforce` mode every user must be in exactly one team, and each team can use only its allowed models.

**3. Only if you want Grafana** (skip this otherwise). Replace the two `<...>` values first; the admin object ID is the admin's **user object ID in this tenant**:
```powershell
jq --arg n "<prefix>-grafana" --arg l $Region --arg a "<admin-user-object-id>" '.options.grafana=true | .grafanaName=$n | .grafanaLocation=$l | .grafanaAdminPrincipalId=$a' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
```

**4. Check the settings and validate** (required):
```powershell
jq '{resourceGroup, apimName, namePrefix, workspaceResourceId, gatewayAudience, pythonExecutable, mode: .teamGovernance.mode, grafana: .options.grafana, pricesReviewed: .options.pricesReviewed}' admin\setup.local.json
jq '.teamGovernance.teams[] | {id, profile, defaultUserTier, allowedModels, members}' admin\setup.local.json
jq -e -f admin\validate-config.jq admin\setup.local.json > $null; if ($LASTEXITCODE -eq 0) { 'Config OK' } else { 'Config INVALID' }
```
Check that the resource group and the workspace ID belong to this deployment, the mode is what you want, `grafana` is `false` unless you chose step 3, `pricesReviewed` is `true`, and the result is `Config OK`. If you ran step 2 or 3 by mistake, run them again with the values you want (for example `"enforce"`, or `.options.grafana=false`).

### C5. Deploy (45–60 minutes)
**Why:** creates everything in the right order, because later parts need outputs from earlier ones:
1. API Management (first without its policy, to get its managed identity)
2. Tier and pricing data in Log Analytics
3. The budget platform: Event Hub, Redis, Cosmos DB, storage and the two Function Apps
4. Loads the model prices and publishes the Function code
5. Team groups, members and roles in Entra, and the team settings in the gateway
6. The final APIM policy (sign-in check, limits, budget check, call to Foundry)
7. The client settings file for developers, and the workbook

Before you start:
- Keep the computer **plugged in**, and set sleep to **Never** for the duration (Settings > System > Power). If the computer sleeps, the Azure sign-in expires and the run stops with `ExpiredAuthenticationToken`.
- Keep the window open, and **do not click inside it** while it runs: selecting text can pause the program. If the window seems frozen, press **Esc**.
- To watch progress, read the log from **another** PowerShell window with `Get-Content logs\claude-gateway-setup.log -Tail 20` (without `-Wait`, which can keep the file locked for the next run).

```powershell
.\admin\claude-gateway-setup.ps1 -ConfigPath admin\setup.local.json -NonInteractive -Yes -Debug -LogFile logs\claude-gateway-setup.log
```
Expected last line: `Selected steps completed. ...`

**If it stops:** read the end of the log, fix the cause (see the operations guide, Troubleshooting), sign in again if needed, and run the **same command** again. Existing resources are reused, so a rerun continues where it stopped.
```powershell
Get-Content logs\claude-gateway-setup.log -Tail 30
az login --tenant $Tenant
az account set --subscription $Sub
```

---

## Part D: Verify

### D1. Deployments and Entra objects
**Why:** confirms that each part was deployed, and that the Entra groups, members and roles match the configuration.

```powershell
az deployment group list -g $Rg --query "[].{name:name, state:properties.provisioningState}" -o table
.\admin\setup-teams-governance-claude-gateway.ps1 -ConfigPath admin\setup.local.json -Check
az ad app show --id (jq -r .gatewayAudience admin\setup.local.json) --query "appRoles[].value" -o tsv
```
- `04-apim-gateway`, `14-claude-tiers`, `16-budget-platform`, `22-team-governance` and `09-workbook` show **Succeeded**. A failed `Failure-Anomalies-Alert-Rule` deployment is added by Azure and can be ignored. `PolicyDeployment_...` entries come from your organization's Azure Policy, not from this setup.
- The governance check ends with `Team governance reconciliation complete`.
- The roles include `Claude.User`, the tier roles and the team and profile roles.

### D2. Allow developers to sign in with Azure CLI
**Why:** Claude Code (CLI and VS Code) gets its gateway token through Azure CLI. Many organizations do not let users approve this themselves ("Need admin approval"). Pre-approving Azure CLI once avoids that for every developer.

See the operations guide, "Allow Azure CLI to request gateway tokens". Skip this if an Entra admin has granted consent instead.

### D3. End-to-end test as a user
**Why:** proves the whole path works: sign-in, role check, API Management, budget check and Foundry. The first test call has no token and must be rejected (401); the second, with your token, must succeed (200).

Use an account that is in a team (it then has the `Claude.User` role):
```powershell
.\developer\setup-claude-workstation.ps1 -ConfigPath developer\claude-client-configuration.json -DryRun
.\developer\setup-claude-workstation.ps1 -ConfigPath developer\claude-client-configuration.json -Login -TestOnly
```
Expected: `Smoke tests passed: unauthenticated 401; authenticated inference 200.`
`-TestOnly` changes no settings and makes one small billable request. Afterwards, run `az account set --subscription $Sub` if later commands use the wrong subscription.

### D4. Team governance checks (enforce mode)
**Why:** proves that the `enforce` rules block what they should, before your users rely on them.

Run these with real users after the smoke test (each makes at most one small billable request):

| Test | Expected |
|---|---|
| Team member calls an allowed model | Success (200) |
| Team member calls a model **not** in the team's `allowedModels` | 403 with header `x-claude-denied-by: team-model-policy` |
| User with `Claude.User` but in no team | 403 with header `x-claude-denied-by: identity` |

Each team's allowed models also cover their Foundry deployments, whatever the deployment names are (for example `claude-sonnet-5-apim` counts as `claude-sonnet-5`). The setup looks the names up each time it deploys the team settings.

To see the result in PowerShell, call the gateway with a token (replace the model name with a deployment name from B3):
```powershell
$cfg = Get-Content -Raw developer\claude-client-configuration.json | ConvertFrom-Json
$res = ($cfg.gatewaySso.scopes -split ' ' | Where-Object { $_ -like 'api://*' }) -replace '/[^/]+$',''
$tok = az account get-access-token --resource $res --query accessToken -o tsv
$body = @{ model = '<model-deployment-name>'; max_tokens = 16; messages = @(@{ role = 'user'; content = 'Reply with READY' }) } | ConvertTo-Json -Depth 5
$r = Invoke-WebRequest -Uri "$($cfg.gatewayUrl)/v1/messages" -Method Post -ContentType 'application/json' -Headers @{ 'anthropic-version' = '2023-06-01'; 'x-api-key' = $tok; Authorization = 'Bearer unused' } -Body $body -SkipHttpErrorCheck
$r.StatusCode; $r.Headers['x-claude-denied-by']
```

### D5. Usage tracking
**Why:** proves that usage events reach Log Analytics and that cost is attributed to the right user and team, which the budgets depend on.

After 5–15 minutes, open the Log Analytics workspace > **Workbooks** > **Claude team governance**. The test calls appear under the team and the user, with tokens and estimated cost.

### D6. Hand over to developers
**Why:** developers need only these files; they contain no secrets and no Azure resource details.

- `developer\claude-client-configuration.json`
- `developer\setup-claude-workstation.ps1` and `developer\setup-claude-workstation.sh`
- `04-developer-onboarding-guide.md`

---

## Next steps

Adding teams, changing budgets, re-exporting settings, Grafana and clean-up are covered in `05-operations-guide.md`, along with troubleshooting.
