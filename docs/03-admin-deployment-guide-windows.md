# Claude on Azure gateway: admin deployment guide (Windows / PowerShell)

This guide deploys the gateway from Windows with **PowerShell 7.3 or newer** (`pwsh`).
For Linux, see `02-admin-deployment-guide-linux.md`.

Complete `01-prerequisites-checklist.md` first.

**Time:** about 15 minutes of preparation, then 45–60 minutes for the deployment (most of it is creating API Management).

> Use PowerShell 7 (`pwsh`), not Windows PowerShell 5.1. Do not run the `.sh` scripts in Git Bash.

---

## Part A: Prepare the machine (one time)

### A1. Install the tools
In any PowerShell window:
```powershell
winget install Microsoft.PowerShell
winget install jqlang.jq
winget install Microsoft.AzureCLI
winget install Python.Python.3.13
winget install Microsoft.Azure.FunctionsCoreTools
```
Close the window and open **PowerShell 7** (Windows key + R, type `pwsh`, press Enter). Then:
```powershell
$PSVersionTable.PSVersion          # 7.3 or higher
jq --version
python --version                   # Python 3.x; if the Microsoft Store opens, Python is not installed
func --version                     # 4.x
az bicep install
az extension add -n quota
```

### A2. Get the repository and the Python environment
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

### B1. Sign in
```powershell
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
az account show --query "{tenant:tenantId, subscription:name}" -o table
```

### B2. Check the Foundry model deployments
```powershell
az cognitiveservices account deployment list -g <foundry-rg> -n <foundry-name> --query "[].{deployment:name, model:properties.model.name}" -o table
```
There must be **exactly one** deployment of each: Opus, Sonnet and Haiku.

### B3. Register resource providers
```powershell
$Providers = 'Microsoft.Quota','Microsoft.ApiManagement','Microsoft.Web','Microsoft.Cache','Microsoft.DocumentDB','Microsoft.EventHub','Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Storage','Microsoft.Dashboard'
foreach ($p in $Providers) { az provider register --namespace $p }
foreach ($p in $Providers) { "{0,-32} {1}" -f $p, (az provider show -n $p --query registrationState -o tsv) }
```
Repeat the second loop until every provider shows `Registered`.

### B4. Check EP1 quota
```powershell
$Scope = "/subscriptions/<subscription-id>/providers/Microsoft.Web/locations/<region>"
az quota show --resource-name EP1 --scope $Scope --query "properties.limit.value" -o tsv
az quota usage show --resource-name EP1 --scope $Scope --query "properties.usages.value" -o tsv
```
The limit minus the usage must be **2 or more**.

---

## Part C: Deploy

### C1. Create the gateway app with all roles
```powershell
.\admin\create-claude-gateway-app.ps1 -TenantId <tenant-id> -DisplayName "Claude Gateway - <apim-name>" -DryRun
.\admin\create-claude-gateway-app.ps1 -TenantId <tenant-id> -DisplayName "Claude Gateway - <apim-name>" -Yes
```
The output lists the roles `Claude.User`, `Claude.Tier.Pro`, `Claude.Tier.Basic` and `Claude.Suspended`.

### C2. Optional: dry run (no Azure calls, nothing saved)
```powershell
.\admin\claude-gateway-setup.ps1 -Interactive -DryRun
```
Expected: `DRY RUN: configuration validated.`

### C3. Preflight (asks questions, saves the answers, deploys nothing)
```powershell
.\admin\claude-gateway-setup.ps1 -Interactive -Stage preflight -Debug -LogFile logs\preflight.log
```

| Question | Answer |
|---|---|
| Subscription ID, Tenant ID | The GUIDs |
| Publisher name | Press Enter, or your team name |
| Gateway resource group name | The gateway resource group |
| Foundry resource group name | The resource group of the Foundry resource |
| APIM name | Your chosen name |
| APIM location | Region for APIM and the budget platform |
| Workspace location | The **existing** workspace's region |
| Workbook location | Region for the workbook |
| Publisher email | Admin email |
| Gateway service principal name | **The same name as in C1** (the default suggestion matches) |
| Log Analytics workspace resource ID | The full resource ID |
| Foundry resource name | The Foundry resource |
| Resource name prefix | 3–11 lowercase letters or digits |
| Python executable | `C:\Users\<you>\claude-venv-win\Scripts\python.exe` |
| Configure team governance now? | `yes`, then the team details from the checklist |

Team member sign-in names are entered comma-separated, without spaces. If an answer has the wrong format (for example the prefix or the workspace ID), the script asks again.

Expected result:
```
Saved interactive configuration to ...\admin\setup.local.json.
Preflight passed; ... no Azure resource deployments were made.
```
Yellow `A new Bicep release is available` warnings are harmless (`az bicep upgrade` removes them).

### C4. Review the saved configuration
```powershell
jq '{resourceGroup, apimName, namePrefix, gatewayAudience, pythonExecutable}' admin\setup.local.json
```
Confirm that the prices are reviewed:
```powershell
jq '.options.pricesReviewed=true' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
```
**Optional: Grafana.** Use the admin's **user object ID in this tenant**:
```powershell
jq --arg n "<prefix>-grafana" --arg l "<region>" --arg a "<admin-user-object-id>" '.options.grafana=true | .grafanaName=$n | .grafanaLocation=$l | .grafanaAdminPrincipalId=$a' admin\setup.local.json | Set-Content admin\setup.tmp.json
Move-Item -Force admin\setup.tmp.json admin\setup.local.json
```
Validate:
```powershell
jq -e -f admin\validate-config.jq admin\setup.local.json > $null; if ($LASTEXITCODE -eq 0) { 'Config OK' } else { 'Config INVALID' }
```

### C5. Deploy (45–60 minutes)
Keep the computer plugged in and awake, and keep the window open.
```powershell
.\admin\claude-gateway-setup.ps1 -ConfigPath admin\setup.local.json -NonInteractive -Yes -Debug -LogFile logs\claude-gateway-setup.log
```
Expected last line: `Selected steps completed. ...`
The deployment is safe to repeat with the **same names**. If it stops, read the end of the log:
```powershell
Get-Content logs\claude-gateway-setup.log -Tail 30
```

---

## Part D: Verify

### D1. Deployments and Entra objects
```powershell
az deployment group list -g <resource-group> --query "[].{name:name, state:properties.provisioningState}" -o table
.\admin\setup-teams-governance-claude-gateway.ps1 -ConfigPath admin\setup.local.json -Check
az ad app show --id (jq -r .gatewayAudience admin\setup.local.json) --query "appRoles[].value" -o tsv
```
- `04-apim-gateway`, `14-claude-tiers`, `16-budget-platform`, `22-team-governance` and `09-workbook` show **Succeeded**. A failed `Failure-Anomalies-Alert-Rule` deployment is added by Azure and can be ignored.
- The governance check ends with `Team governance reconciliation complete`.
- The roles include `Claude.User`, the tier roles and the team and profile roles.

### D2. Allow developers to sign in with Azure CLI
Do this once, unless an Entra admin has granted consent instead. See the operations guide, "Allow Azure CLI to request gateway tokens".

### D3. End-to-end test as a user
Use an account that is in a team (it then has the `Claude.User` role):
```powershell
.\developer\setup-claude-workstation.ps1 -ConfigPath developer\claude-client-configuration.json -DryRun
.\developer\setup-claude-workstation.ps1 -ConfigPath developer\claude-client-configuration.json -Login -TestOnly
```
Expected: `Smoke tests passed: unauthenticated 401; authenticated inference 200.`
`-TestOnly` changes no settings and makes one small billable request. Afterwards, run `az account set --subscription <subscription-id>` if later commands use the wrong subscription.

### D4. Usage tracking
After 5–15 minutes, open the Log Analytics workspace > **Workbooks** > **Claude team governance**. The test calls appear under the team and the user, with tokens and estimated cost.

### D5. Hand over to developers
Give developers:
- `developer\claude-client-configuration.json` (contains no secrets)
- `developer\setup-claude-workstation.ps1` and `developer\setup-claude-workstation.sh`
- `04-developer-onboarding-guide.md`

---

## Next steps

Adding teams, changing budgets, re-exporting settings, Grafana and clean-up are covered in `05-operations-guide.md`, along with troubleshooting.
