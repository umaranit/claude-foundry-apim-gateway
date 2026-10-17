# Claude on Azure gateway: documentation

Use these documents in order.

| # | Document | Audience | When |
|---|---|---|---|
| 1 | [Prerequisites checklist](01-prerequisites-checklist.md) | Customer admins, Entra and Azure owners | Before the deployment session |
| 2 | [Admin deployment guide: Linux / Bash](02-admin-deployment-guide-linux.md) | Platform admin | Deployment (recommended runner) |
| 3 | [Admin deployment guide: Windows / PowerShell](03-admin-deployment-guide-windows.md) | Platform admin | Deployment from Windows |
| 4 | [Developer onboarding guide](04-developer-onboarding-guide.md) | Developers | After the deployment |
| 5 | [Operations guide](05-operations-guide.md) | Platform admin | Teams, budgets, monitoring, clean-up, troubleshooting |

## Files that must never be committed

`admin/setup.local.json`, `admin/setup.rejected.json`, `developer/claude-client-configuration.json` and `logs/` contain environment details (tenant, subscription, resource names, user names). Suggested `.gitignore` entries:
```
admin/setup.local.json
admin/setup.local.*.json
admin/setup.rejected.json
admin/setup.tmp.json
developer/claude-client-configuration.json
logs/
```
Suggested `.gitattributes` entries, so Windows checkouts keep Linux line endings for the Bash scripts:
```
*.sh text eol=lf
*.jq text eol=lf
```
