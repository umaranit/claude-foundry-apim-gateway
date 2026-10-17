# Claude on Azure gateway: developer onboarding guide

This guide connects **Claude Code (CLI)**, the **Claude Code VS Code extension** and **Claude Desktop** to your organization's Claude gateway.

## What you need from your administrator

- `claude-client-configuration.json`: the gateway settings (no passwords or keys)
- `setup-claude-workstation.ps1` (Windows) or `setup-claude-workstation.sh` (macOS / Linux)
- Membership of a Claude team, which gives you the `Claude.User` role. Ask your administrator if you are not sure.

Never replace the values in the configuration file with an API key, and never paste access tokens into it.

## Prerequisites

| | Windows | macOS / Linux |
|---|---|---|
| Shell | PowerShell 7.2+ (`pwsh`), not Windows PowerShell 5.1 | Bash |
| Tools | Azure CLI | Azure CLI and `jq` |
| Claude Code | Already installed, or Node.js/npm to install it with the script | Same |
| VS Code extension (optional) | `code` command on PATH | Same |

---

## Part 1: Claude Code CLI and VS Code

Run the commands from the folder that contains the script and the configuration file.

### Step 1: Preview (no changes, no sign-in)
Windows:
```powershell
.\setup-claude-workstation.ps1 -ConfigPath .\claude-client-configuration.json -DryRun
```
macOS / Linux:
```bash
bash setup-claude-workstation.sh --config ./claude-client-configuration.json --dry-run
```
It shows the gateway URL and the settings file that will be updated.

### Step 2: Test your access (no changes)
Windows:
```powershell
.\setup-claude-workstation.ps1 -ConfigPath .\claude-client-configuration.json -Login -TestOnly
```
macOS / Linux:
```bash
bash setup-claude-workstation.sh --config ./claude-client-configuration.json --login --test-only
```
A sign-in window opens. Sign in with your work account.
Expected: `Smoke tests passed: unauthenticated 401; authenticated inference 200.`
This makes one small billable request.

### Step 3: Configure Claude Code
Windows:
```powershell
.\setup-claude-workstation.ps1 -ConfigPath .\claude-client-configuration.json -Login
```
macOS / Linux:
```bash
bash setup-claude-workstation.sh --config ./claude-client-configuration.json --login
```
Add `-InstallClaude` / `--install-claude` to install Claude Code with npm, and `-InstallVSCode` / `--install-vscode` to install the VS Code extension.

Then restart Claude Code, or reload VS Code.

### What the script changes
- It updates `~/.claude/settings.json` (a timestamped backup is made first): the gateway URL, the Opus/Sonnet/Haiku model names, and a token helper.
- The token helper gets a short-lived Entra token through Azure CLI when Claude Code needs one. No token is stored in the settings.
- It removes conflicting settings (other API keys, other providers, forced login). If conflicting **environment variables** such as `ANTHROPIC_API_KEY` are set, it stops; remove them from your profile and run it again.

### Undo
Close Claude Code, restore the settings backup in `~/.claude/`, and delete the `gateway` folder there.

---

## Part 2: Claude Desktop

### Step 1: Get the values
Windows:
```powershell
Get-Content .\claude-client-configuration.json
```
macOS / Linux:
```bash
cat ./claude-client-configuration.json
```

### Step 2: Fill in the settings
In Claude Desktop, open **Configure third-party inference > Connection** and choose **Gateway**.

| Desktop field | Value from the file |
|---|---|
| Credential kind | **Interactive sign-in** |
| Gateway base URL | `gatewayUrl` (ends with `/anthropic`) |
| Sign-in session lifetime | Leave blank |
| Gateway sign-in flow | **browser** |
| Client ID | `gatewaySso.clientId` |
| Issuer URL | `gatewaySso.issuerUrl` (`https://login.microsoftonline.com/<tenant-id>/v2.0`) |
| Bearer token | **Access token** (not ID token) |
| Scopes | The **whole value** of `gatewaySso.scopes`, for example `openid profile api://<gateway-app-id>/access_as_user` |
| Append offline_access | On |
| Redirect port | Leave as (ephemeral) |
| Redirect host | 127.0.0.1 |
| Other fields (resource indicator, referrer hosts, iframe origin, custom headers) | Leave blank |
| Stream idle timeout | 300 |
| Model list | Add `models.opus`, `models.sonnet` and `models.haiku` as Model IDs (the first entry is the default) |

To copy the scopes exactly, without typing:
- Windows: `jq -r .gatewaySso.scopes .\claude-client-configuration.json | Set-Clipboard`
- macOS: `jq -r .gatewaySso.scopes ./claude-client-configuration.json | pbcopy`

Claude Desktop may show notes that some setting names (for example `interactive` and `inferenceGatewayOidc`) are deprecated. They still work.

### Step 3: Test
Select **Test connection** and sign in in the browser. Expected: `Connected. You can close this tab.` Then start a chat.

---

## Troubleshooting

Gateway denials include the header `x-claude-denied-by`, which names the reason.


| What you see | Cause | What to do |
|---|---|---|
| "Need admin approval – Microsoft Azure CLI" | Azure CLI is not yet allowed to request gateway tokens in your organization | Ask your administrator (operations guide: "Allow Azure CLI to request gateway tokens") |
| "Need admin approval" in Claude Desktop | Your organization requires admin consent for the Desktop app | Ask your administrator to grant consent |
| Desktop: `Provider returned error: invalid_client` or "Authentication failed" | Wrong Scopes, Client ID or Issuer URL | Copy the values again from the file; paste the **whole** scopes value |
| No token / sign-in expired | Azure CLI sign-in expired | Run the script again with `-Login` / `--login` |
| 401 | No `Claude.User` role, or wrong token type | Ask your administrator to check your team membership (new roles can take a few minutes); in Desktop select **Access token** |
| 403 `identity` | You are not in exactly one Claude team | Ask your administrator to add you to one team (and remove you from any other); then sign in again |
| 403 `team-model-policy` | The model is not allowed for your team | Use an allowed model, or ask your administrator |
| 403 `user-budget` or `team-budget` | Your or your team's monthly budget is used up | Ask your administrator |
| 403 `admin` | Your access is suspended | Ask your administrator |
| 429 (`user-token-limit` or `team-token-limit`) | Rate or token limit reached | Wait and retry, or ask your administrator |
| Model not found | Model names differ from the deployments | Ask your administrator for a fresh configuration file |
| Settings ignored | Organization-managed or project settings take priority | Check those settings, or ask your administrator |
