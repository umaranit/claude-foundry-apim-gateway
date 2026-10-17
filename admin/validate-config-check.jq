# Diagnostic: evaluates each rule of admin/validate-config.jq separately.
# Usage: jq -f validate-config-check.jq admin/setup.rejected.json
def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
def positive: type == "number" and . > 0 and floor == .;
def uniqueBy(f): (map(f) | length) == (map(f) | unique | length);
def supportedModels: ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"];
def check(f): try f catch ("ERROR: " + tostring);
(. + {foundryResourceGroup: (.foundryResourceGroup // .resourceGroup)}) as $config |
$config |
{
  "01 ids are GUIDs": check([.subscriptionId, .tenantId, .gatewayAudience] | all(.[]; guid)),
  "02 pricing principal": check((.pricingPublisherPrincipalId // "") == "" or (.pricingPublisherPrincipalId | guid)),
  "03 budget audience": check((.budgetApiAudience == "") or (.budgetApiAudience | guid)),
  "04 text fields": check([.resourceGroup, .foundryResourceGroup, .apimName, .foundryAccountName, .publisherEmail, .publisherName, .apimLocation,
    .budgetLocation, .cosmosLocation, .workspaceLocation, .workbookLocation, .pythonExecutable,
    .onboardingOutput] | all(.[]; type == "string" and length > 0 and (test("[<>\r\n]") | not))),
  "05 model names": check([.models.opus, .models.sonnet, .models.haiku] | all(.[]; type == "string" and (test("[<>\r\n]") | not))),
  "05b model names (empty-string regex test)": check(["", "x"] | map(test("[<>\r\n]"))),
  "06 prefix": check(.namePrefix | test("^[a-z0-9]{3,11}$")),
  "07 workspace id format": check(.workspaceResourceId | test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$"; "i")),
  "08 workspace subscription": check((.workspaceResourceId | split("/")[2] | ascii_downcase) == (.subscriptionId | ascii_downcase)),
  "09 regions and audiences": check((.apimLocation == .budgetLocation) and (.gatewayAudience != .budgetApiAudience)),
  "10 token resource": check(.tokenResource | test("^(api://|https://)[A-Za-z0-9./:_-]+$")),
  "11 pricing principal type": check((.pricingPublisherPrincipalType // "") == "" or .pricingPublisherPrincipalType == "User" or .pricingPublisherPrincipalType == "ServicePrincipal"),
  "12 redis": check((.redisSku == "Standard" or .redisSku == "Premium") and (.redisCapacity | positive)),
  "13 storage tags": check(.storageGovernanceTags | type == "object"),
  "14 tiers": check(.tiersConfig | type == "array" and length == 3 and (map(.name) | sort == ["basic", "lite", "pro"]) and
    all(.[]; (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))),
  "15 retention and reconcile": check((.retentionTimeoutSeconds | positive) and (.reconcileHours | positive and . <= 2232)),
  "16 options are booleans": check([.options.registerProviders, .options.checkEp1Quota, .options.pricesReviewed, .options.workbook,
    .options.summaryRule, .options.grafana, .options.reconcile, .options.smokeTest] | all(.[]; type == "boolean")),
  "17 grafana": check(if .options.grafana then (.grafanaName | type == "string" and length > 0) and
    (.grafanaLocation | type == "string" and length > 0) and (.grafanaAdminPrincipalId | guid) else true end),
  "18 team mode": check(if .teamGovernance == null then true else (.teamGovernance.mode as $mode | ($mode == "off" or $mode == "observe" or $mode == "enforce")) end),
  "19 action groups": check(if .teamGovernance == null then true else ((.teamGovernance.actionGroupIds // []) | type == "array" and uniqueBy(.) and
      all(.[]; type == "string" and test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Insights/actionGroups/[^/]+$"; "i"))) end),
  "20 profiles": check(if .teamGovernance == null then true else (.teamGovernance.profiles | type == "array" and length > 0 and
      uniqueBy(.name) and uniqueBy(.roleValue) and
      all(.[]; (.name | type == "string" and test("^[a-z0-9-]{2,30}$")) and
        (.roleValue | type == "string" and test("^Claude\\.TeamProfile\\.[A-Za-z0-9]+$")) and
        (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))) end),
  "21 teams unique ids": check(if .teamGovernance == null then true else (.teamGovernance.teams | type == "array" and length > 0 and
      uniqueBy(.id) and uniqueBy(.groupDisplayName) and uniqueBy(.teamRoleValue)) end),
  "22 teams members not shared": check(if .teamGovernance == null then true else (.teamGovernance.teams |
      ([.[] | .members[]?] as $allMembers | ($allMembers | length) == ($allMembers | unique | length))) end),
  "23 team id/name/group/role": check(if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
        (.id | type == "string" and test("^[a-z0-9-]{3,50}$")) and
        (.displayName | type == "string" and length > 0 and (test("[<>\r\n]") | not)) and
        (.groupDisplayName | type == "string" and length > 0 and (test("[<>\r\n]") | not)) and
        (.teamRoleValue | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$")))) end),
  "24 team profile reference": check(if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
        (.profile as $p | ($config.teamGovernance.profiles | map(.name) | index($p)) != null))) end),
  "24b profile index value": check([$config.teamGovernance.teams[]? | .profile as $p | ($config.teamGovernance.profiles | map(.name) | index($p))]),
  "25 team tier reference": check(if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
        (.defaultUserTier as $t | ($config.tiersConfig | map(.name) | index($t)) != null))) end),
  "25b tier index value": check([$config.teamGovernance.teams[]? | .defaultUserTier as $t | ($config.tiersConfig | map(.name) | index($t))]),
  "26 allowed models": check(if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
        ((.allowedModels == null) or (.allowedModels | type == "array" and length > 0 and uniqueBy(.) and
          all(.[]; type == "string" and . as $model | (supportedModels | index($model)) != null))))) end),
  "26b model index values": check([$config.teamGovernance.teams[]?.allowedModels[]? as $model | (supportedModels | index($model))]),
  "27 members are emails": check(if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
        (.members | type == "array" and length > 0 and
          all(.[]; type == "string" and length > 0 and test("^[^<>\r\n]+@[^<>\r\n]+$"))))) end)
}
