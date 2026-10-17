# Claude on Azure gateway: admin deployment guide (Linux / Bash)

This guide deploys the gateway from a Linux shell: Ubuntu, WSL on Windows, a Linux VM, or Azure Cloud Shell with a storage account mounted.
For Windows with PowerShell, see `03-admin-deployment-guide-windows.md`.

Complete `01-prerequisites-checklist.md` first.

**Time:** about 15 minutes of preparation, then 45–60 minutes for the deployment (most of it is creating API Management).

> Do not use Git Bash on Windows. The Windows versions of `az` and `jq` add hidden carriage-return characters that break the scripts.

---

## Part A: Prepare the machine (one time)

### A1. Install the tools
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
**On WSL:** check that `which az jq func` all show `/usr/bin/...`. A path starting with `/mnt/c/` is the Windows version; install the Linux version as above.

### A2. Get the repository and the Python environment
Clone **inside Linux**. Do not copy `.sh` files from a Windows folder; Windows line endings break them.
```bash
cd ~
git clone https://github.com/umaranit/claude-foundry-apim-gateway.git
cd claude-foundry-apim-gateway
chmod +x admin/*.sh && mkdir -p logs
python3 -m venv ~/claude-venv
source ~/claude-venv/bin/activate
pip install azure-identity azure-monitor-ingestion requests redis
```

---

## Part B: Prepare the subscription

### B1. Sign in
```bash
az login --tenant <tenant-id>
az account set --subscription <subscription-id>
az account show --query "{tenant:tenantId, subscription:name}" -o table
```
If Conditional Access requires a managed device, use the browser sign-in (not `--use-device-code`). On WSL, if the browser does not open, copy the sign-in link from the terminal into your Windows browser.

### B2. Check the Foundry model deployments
```bash
az cognitiveservices account deployment list -g <foundry-rg> -n <foundry-name> \
  --query "[].{deployment:name, model:properties.model.name}" -o table
```
There must be **exactly one** deployment of each: Opus, Sonnet and Haiku. Deployment names can be anything; the setup detects them.

### B3. Register resource providers
```bash
PROVIDERS="Microsoft.Quota Microsoft.ApiManagement Microsoft.Web Microsoft.Cache Microsoft.DocumentDB Microsoft.EventHub Microsoft.Insights Microsoft.OperationalInsights Microsoft.Storage Microsoft.Dashboard"
for p in $PROVIDERS; do az provider register --namespace $p; done
for p in $PROVIDERS; do echo "$p: $(az provider show -n $p --query registrationState -o tsv)"; done
```
Repeat the second loop until every provider shows `Registered`.

### B4. Check EP1 quota
```bash
SCOPE="/subscriptions/<subscription-id>/providers/Microsoft.Web/locations/<region>"
az quota show --resource-name EP1 --scope "$SCOPE" --query "properties.limit.value" -o tsv
az quota usage show --resource-name EP1 --scope "$SCOPE" --query "properties.usages.value" -o tsv
```
The limit minus the usage must be **2 or more**. If not, request more quota or choose another region.

---

## Part C: Deploy

### C1. Create the gateway app with all roles
```bash
./admin/create-claude-gateway-app.sh --tenant-id <tenant-id> --display-name "Claude Gateway - <apim-name>" --dry-run
./admin/create-claude-gateway-app.sh --tenant-id <tenant-id> --display-name "Claude Gateway - <apim-name>" --yes
```
The output lists the roles `Claude.User`, `Claude.Tier.Pro`, `Claude.Tier.Basic` and `Claude.Suspended`. Note the `gatewayAudience` value (the app ID).

### C2. Preflight (asks questions, saves the answers, deploys nothing)
```bash
./admin/claude-gateway-setup.sh --interactive --stage preflight
```

| Question | Answer |
|---|---|
| Subscription ID, Tenant ID | The GUIDs |
| Publisher name | Press Enter, or your team name |
| Resource group name | The gateway resource group |
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
| Configure team governance now? | `yes`, then the team details from the checklist |

Team member sign-in names are entered comma-separated, without spaces.

Expected result:
```
Saved interactive configuration to .../admin/setup.local.json.
Preflight passed; ... no Azure resource deployments were made.
```

### C3. Review the saved configuration
```bash
jq '{resourceGroup, apimName, namePrefix, gatewayAudience, pythonExecutable}' admin/setup.local.json
```
Set the Python path and confirm that the prices are reviewed:
```bash
jq --arg p "$HOME/claude-venv/bin/python" '.pythonExecutable=$p | .options.pricesReviewed=true' \
  admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
```
**Optional: Grafana.** Use the admin's **user object ID in this tenant**:
```bash
jq --arg n "<prefix>-grafana" --arg l "<region>" --arg a "<admin-user-object-id>" \
  '.options.grafana=true | .grafanaName=$n | .grafanaLocation=$l | .grafanaAdminPrincipalId=$a' \
  admin/setup.local.json > /tmp/setup.json && mv /tmp/setup.json admin/setup.local.json
```
Validate:
```bash
jq -e -f admin/validate-config.jq admin/setup.local.json > /dev/null && echo "Config OK"
```

### C4. Deploy (45–60 minutes)
Run inside `tmux` so a dropped connection does not stop the deployment. Keep the machine awake.
```bash
tmux new -s claude
source ~/claude-venv/bin/activate
cd ~/claude-on-azure-sombaner
./admin/claude-gateway-setup.sh --config admin/setup.local.json --non-interactive --yes \
  --debug --log-file logs/claude-gateway-setup.log
```
If the terminal disconnects, reconnect and run `tmux attach -t claude`.
Expected last line: `Selected steps completed. ...`
The deployment is safe to repeat with the **same names**. It creates API Management only if it does not exist.

---

## Part D: Verify

### D1. Deployments and Entra objects
```bash
az deployment group list -g <resource-group> --query "[].{name:name, state:properties.provisioningState}" -o table
./admin/setup-teams-governance-claude-gateway.sh --config admin/setup.local.json --check
az ad app show --id "$(jq -r .gatewayAudience admin/setup.local.json)" --query "appRoles[].value" -o tsv
```
- `04-apim-gateway`, `14-claude-tiers`, `16-budget-platform`, `22-team-governance` and `09-workbook` show **Succeeded**. A failed `Failure-Anomalies-Alert-Rule` deployment is added by Azure and can be ignored.
- The governance check ends with `Team governance reconciliation complete`.
- The roles include `Claude.User`, the tier roles and the team and profile roles.

### D2. Allow developers to sign in with Azure CLI
Do this once, unless an Entra admin has granted consent instead. See the operations guide, "Allow Azure CLI to request gateway tokens".

### D3. End-to-end test as a user
Use an account that is in a team (it then has the `Claude.User` role):
```bash
bash developer/setup-claude-workstation.sh --config developer/claude-client-configuration.json --dry-run
bash developer/setup-claude-workstation.sh --config developer/claude-client-configuration.json --login --test-only
```
Expected: `Smoke tests passed: unauthenticated 401; authenticated inference 200.`
`--test-only` changes no settings and makes one small billable request.

### D4. Usage tracking
After 5–15 minutes, open the Log Analytics workspace > **Workbooks** > **Claude team governance**. The test calls appear under the team and the user, with tokens and estimated cost.

### D5. Hand over to developers
Give developers:
- `developer/claude-client-configuration.json` (contains no secrets)
- `developer/setup-claude-workstation.sh` and `developer/setup-claude-workstation.ps1`
- `04-developer-onboarding-guide.md`

---

## Next steps

Adding teams, changing budgets, re-exporting settings, Grafana and clean-up are covered in `05-operations-guide.md`, along with troubleshooting.
