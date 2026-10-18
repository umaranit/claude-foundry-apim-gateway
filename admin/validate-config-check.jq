# Explains admin/validate-config.jq rule by rule.
# Output: an array of {rule, ok, detail?}. The setup scripts print the rules with ok=false.
# Manual use: jq -f admin/validate-config-check.jq admin/setup.local.json
def guid: type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$");
def positive: type == "number" and . > 0 and floor == .;
def uniqueBy(f): (map(f) | length) == (map(f) | unique | length);
def supportedModels: ["claude-sonnet-5", "claude-haiku-4-5", "claude-opus-5"];
def filled: type == "string" and length > 0 and (test("[<>\r\n]") | not);
def rule(name; f; d):
  (try (if f then {rule: name, ok: true} else {rule: name, ok: false, detail: (try d catch null)} end)
   catch {rule: name, ok: false, detail: ("check error: " + tostring)})
  | if .detail == null then del(.detail) else . end;
(. + {foundryResourceGroup: (.foundryResourceGroup // .resourceGroup)}) as $config |
$config |
[
  rule("Subscription ID, tenant ID and gateway app ID must be GUIDs";
    [.subscriptionId, .tenantId, .gatewayAudience] | all(.[]; guid);
    {subscriptionId, tenantId, gatewayAudience} | [to_entries[] | select(.value | guid | not) | .key] | "not a GUID: " + join(", ")),
  rule("pricingPublisherPrincipalId must be empty or a GUID";
    (.pricingPublisherPrincipalId // "") == "" or (.pricingPublisherPrincipalId | guid);
    .pricingPublisherPrincipalId),
  rule("budgetApiAudience must be empty or a GUID";
    (.budgetApiAudience == "") or (.budgetApiAudience | guid);
    .budgetApiAudience),
  rule("Required settings must be filled in, without <...> placeholders";
    [.resourceGroup, .foundryResourceGroup, .apimName, .foundryAccountName, .publisherEmail, .publisherName, .apimLocation,
     .budgetLocation, .cosmosLocation, .workspaceLocation, .workbookLocation, .pythonExecutable, .onboardingOutput] | all(.[]; filled);
    {resourceGroup, foundryResourceGroup, apimName, foundryAccountName, publisherEmail, publisherName, apimLocation,
     budgetLocation, cosmosLocation, workspaceLocation, workbookLocation, pythonExecutable, onboardingOutput}
    | [to_entries[] | select(.value | filled | not) | .key] | "check: " + join(", ")),
  rule("Model deployment names must not contain placeholders";
    [.models.opus, .models.sonnet, .models.haiku] | all(.[]; type == "string" and (test("[<>\r\n]") | not));
    .models | tostring),
  rule("Resource name prefix must be 3-11 lowercase letters or digits";
    .namePrefix | test("^[a-z0-9]{3,11}$");
    "namePrefix=" + (.namePrefix | tostring)),
  rule("Workspace ID must be a full Log Analytics workspace resource ID";
    .workspaceResourceId | test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft.OperationalInsights/workspaces/[^/]+$"; "i");
    .workspaceResourceId | tostring),
  rule("Workspace must be in the deployment subscription";
    (.workspaceResourceId | split("/")[2] | ascii_downcase) == (.subscriptionId | ascii_downcase);
    "workspace subscription " + (.workspaceResourceId | split("/")[2] | tostring) + ", subscriptionId " + (.subscriptionId | tostring)),
  rule("APIM location must equal budget location, and the gateway and budget API apps must differ";
    (.apimLocation == .budgetLocation) and (.gatewayAudience != .budgetApiAudience);
    "apimLocation=" + (.apimLocation | tostring) + ", budgetLocation=" + (.budgetLocation | tostring)),
  rule("tokenResource must start with api:// or https://";
    .tokenResource | test("^(api://|https://)[A-Za-z0-9./:_-]+$");
    .tokenResource | tostring),
  rule("pricingPublisherPrincipalType must be empty, User or ServicePrincipal";
    (.pricingPublisherPrincipalType // "") == "" or .pricingPublisherPrincipalType == "User" or .pricingPublisherPrincipalType == "ServicePrincipal";
    .pricingPublisherPrincipalType | tostring),
  rule("Redis SKU must be Standard or Premium, with a positive whole capacity";
    (.redisSku == "Standard" or .redisSku == "Premium") and (.redisCapacity | positive);
    "redisSku=" + (.redisSku | tostring) + ", redisCapacity=" + (.redisCapacity | tostring)),
  rule("storageGovernanceTags must be an object";
    .storageGovernanceTags | type == "object";
    .storageGovernanceTags | tostring),
  rule("tiersConfig must contain exactly pro, basic and lite, with positive limits";
    .tiersConfig | type == "array" and length == 3 and (map(.name) | sort == ["basic", "lite", "pro"]) and
      all(.[]; (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive));
    .tiersConfig | tostring),
  rule("retentionTimeoutSeconds and reconcileHours (at most 2232) must be positive whole numbers";
    (.retentionTimeoutSeconds | positive) and (.reconcileHours | positive and . <= 2232);
    "retentionTimeoutSeconds=" + (.retentionTimeoutSeconds | tostring) + ", reconcileHours=" + (.reconcileHours | tostring)),
  rule("Every option must be true or false";
    [.options.registerProviders, .options.checkEp1Quota, .options.pricesReviewed, .options.workbook,
     .options.summaryRule, .options.grafana, .options.reconcile, .options.smokeTest] | all(.[]; type == "boolean");
    .options | tostring),
  rule("With Grafana on, grafanaName and grafanaLocation are required, and grafanaAdminPrincipalId must be empty (signed-in user) or a GUID";
    if .options.grafana then (.grafanaName | type == "string" and length > 0) and
      (.grafanaLocation | type == "string" and length > 0) and ((.grafanaAdminPrincipalId // "") == "" or (.grafanaAdminPrincipalId | guid)) else true end;
    {grafanaName, grafanaLocation, grafanaAdminPrincipalId} | tostring),
  rule("Team governance mode must be off, observe or enforce";
    if .teamGovernance == null then true else (.teamGovernance.mode as $m | ($m == "off" or $m == "observe" or $m == "enforce")) end;
    "mode=" + (.teamGovernance.mode | tostring)),
  rule("Action group IDs must be unique Azure Monitor action group resource IDs";
    if .teamGovernance == null then true else ((.teamGovernance.actionGroupIds // []) | type == "array" and uniqueBy(.) and
      all(.[]; type == "string" and test("^/subscriptions/[^/]+/resourceGroups/[^/]+/providers/Microsoft\\.Insights/actionGroups/[^/]+$"; "i"))) end;
    .teamGovernance.actionGroupIds | tostring),
  rule("Team profiles need unique names (2-30 lowercase letters, digits, hyphens), Claude.TeamProfile.* roles and positive limits";
    if .teamGovernance == null then true else (.teamGovernance.profiles | type == "array" and length > 0 and
      uniqueBy(.name) and uniqueBy(.roleValue) and
      all(.[]; (.name | type == "string" and test("^[a-z0-9-]{2,30}$")) and
        (.roleValue | type == "string" and test("^Claude\\.TeamProfile\\.[A-Za-z0-9]+$")) and
        (.tpm | positive) and (.tokenQuota | positive) and (.costQuota | positive))) end;
    .teamGovernance.profiles | map(.name) | tostring),
  rule("Team IDs, group names and team roles must be unique";
    if .teamGovernance == null then true else (.teamGovernance.teams | type == "array" and length > 0 and
      uniqueBy(.id) and uniqueBy(.groupDisplayName) and uniqueBy(.teamRoleValue)) end;
    .teamGovernance.teams | map(.id) | tostring),
  rule("Each user may be in only one team";
    if .teamGovernance == null then true else (.teamGovernance.teams |
      ([.[] | .members[]?] as $all | ($all | length) == ($all | unique | length))) end;
    [.teamGovernance.teams[]?.members[]?] | group_by(.) | map(select(length > 1) | .[0]) | "in more than one team: " + join(", ")),
  rule("Team IDs must be 3-50 lowercase letters, digits or hyphens; names without < >; team roles 3-120 characters";
    if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
      (.id | type == "string" and test("^[a-z0-9-]{3,50}$")) and
      (.displayName | filled) and (.groupDisplayName | filled) and
      (.teamRoleValue | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$")))) end;
    [.teamGovernance.teams[] | select(((.id | type == "string" and test("^[a-z0-9-]{3,50}$")) and (.displayName | filled) and
      (.groupDisplayName | filled) and (.teamRoleValue | type == "string" and test("^[A-Za-z0-9][A-Za-z0-9._-]{2,119}$"))) | not) | .displayName]
    | "check teams: " + join(", ")),
  rule("Each team's profile must exist in teamGovernance.profiles";
    if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
      (.profile as $p | ($config.teamGovernance.profiles | map(.name) | index($p)) != null))) end;
    [.teamGovernance.teams[] | select(.profile as $p | ($config.teamGovernance.profiles | map(.name) | index($p)) == null) | "\(.id): \(.profile)"] | join(", ")),
  rule("Each team's default tier must be pro, basic or lite";
    if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
      (.defaultUserTier as $t | ($config.tiersConfig | map(.name) | index($t)) != null))) end;
    [.teamGovernance.teams[] | select(.defaultUserTier as $t | ($config.tiersConfig | map(.name) | index($t)) == null) | "\(.id): \(.defaultUserTier)"] | join(", ")),
  rule("Allowed models must be a non-empty, unique list from claude-sonnet-5, claude-haiku-4-5, claude-opus-5";
    if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
      ((.allowedModels == null) or (.allowedModels | type == "array" and length > 0 and uniqueBy(.) and
        all(.[]; type == "string" and (. as $model | (supportedModels | index($model)) != null)))))) end;
    [.teamGovernance.teams[] | "\(.id): \(.allowedModels | tostring)"] | join("; ")),
  rule("Team members must be sign-in names (name@domain)";
    if .teamGovernance == null then true else (.teamGovernance.teams | all(.[];
      (.members | type == "array" and length > 0 and
        all(.[]; type == "string" and length > 0 and test("^[^<>\r\n]+@[^<>\r\n]+$"))))) end;
    [.teamGovernance.teams[] | select((.members | type == "array" and length > 0 and
      all(.[]; type == "string" and length > 0 and test("^[^<>\r\n]+@[^<>\r\n]+$"))) | not) | .id] | "check members of: " + join(", "))
]
