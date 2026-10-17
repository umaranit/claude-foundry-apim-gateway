#!/usr/bin/env bash
set -euo pipefail

DIRECTORY=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TENANT_ID=''
DISPLAY_NAME='Claude Gateway API'
APP_ID=''
DRY_RUN=false
YES=false

usage() {
  cat <<'EOF'
Usage: create-claude-gateway-app.sh --tenant-id GUID [--display-name NAME | --app-id GUID] [--dry-run] [--yes]

Creates or reuses a single-tenant gateway API registration and service principal.
Defines Claude.User, Claude.Tier.Pro, Claude.Tier.Basic and Claude.Suspended
for users/groups, exposes access_as_user, and requests v2 access tokens.
No Desktop registration, secret, Azure RBAC grant or caller assignment is created.
--app-id targets an existing registration. Otherwise an exact display-name match
is reused; ambiguous names fail. --yes authorizes writes. --dry-run is offline.
Prints verified registration details as JSON. Requires az, jq and uuidgen.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tenant-id|--display-name|--app-id)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { usage >&2; exit 2; }
      case "$1" in
        --tenant-id) TENANT_ID=$2 ;;
        --display-name) DISPLAY_NAME=$2 ;;
        --app-id) APP_ID=$2 ;;
      esac
      shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --yes) YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done
GUID_PATTERN='^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$'
[[ "$TENANT_ID" =~ $GUID_PATTERN ]] || { echo '--tenant-id must be a GUID.' >&2; exit 2; }
[[ -z "$APP_ID" || "$APP_ID" =~ $GUID_PATTERN ]] || { echo '--app-id must be a GUID.' >&2; exit 2; }
if [[ "$DRY_RUN" == true ]]; then
  printf 'DRY RUN: tenant=%s; gateway=%s. Ensure API registration, service principal, v2 tokens, access_as_user and Claude.User/Claude.Tier.Pro/Claude.Tier.Basic/Claude.Suspended. No Azure calls or writes.\n' "$TENANT_ID" "${APP_ID:-$DISPLAY_NAME}"
  exit 0
fi
[[ "$YES" == true ]] || { echo 'Review --dry-run, then pass --yes to authorize Entra changes.' >&2; exit 2; }
for tool in az jq uuidgen; do
  command -v "$tool" >/dev/null || { printf '%s is required.\n' "$tool" >&2; exit 1; }
done
azure() { az "$@" --only-show-errors; }
new_guid() { uuidgen | tr '[:upper:]' '[:lower:]'; }

ACCOUNT=$(azure account show -o json)
[[ $(jq -er '.tenantId | ascii_downcase' <<< "$ACCOUNT") == "$(tr '[:upper:]' '[:lower:]' <<< "$TENANT_ID")" ]] || {
  echo 'Wrong Azure tenant. Run az login --tenant <tenant-id> and retry.' >&2; exit 1;
}
if [[ -n "$APP_ID" ]]; then
  APP=$(azure ad app show --id "$APP_ID" -o json)
else
  APPS=$(azure ad app list --display-name "$DISPLAY_NAME" -o json)
  APPS=$(jq -c --arg name "$DISPLAY_NAME" '[.[] | select(.displayName == $name)]' <<< "$APPS")
  COUNT=$(jq 'length' <<< "$APPS")
  [[ "$COUNT" -le 1 ]] || { echo 'Multiple exact-name applications found. Specify --app-id.' >&2; exit 1; }
  if [[ "$COUNT" -eq 1 ]]; then
    APP=$(jq -c '.[0]' <<< "$APPS")
  else
    APP=$(azure ad app create --display-name "$DISPLAY_NAME" --sign-in-audience AzureADMyOrg -o json)
  fi
fi
jq -e '.signInAudience == "AzureADMyOrg"' <<< "$APP" >/dev/null || {
  echo 'The existing registration must be single-tenant (AzureADMyOrg).' >&2; exit 1;
}
APP_ID=$(jq -er .appId <<< "$APP")
OBJECT_ID=$(jq -er .id <<< "$APP")
ROLES='[]'
for value in Claude.User Claude.Tier.Pro Claude.Tier.Basic Claude.Suspended; do
  ROLES=$(jq -c --arg id "$(new_guid)" --arg value "$value" '. + [{
    id: $id, value: $value, displayName: $value,
    description: ("Claude gateway role: " + $value),
    allowedMemberTypes: ["User"], isEnabled: true
  }]' <<< "$ROLES")
done
PATCH=$(jq -ce --arg scopeId "$(new_guid)" --argjson roles "$ROLES" \
  -f "$DIRECTORY/gateway-app-registration.jq" <<< "$APP")
APPLICATION_URL="https://graph.microsoft.com/v1.0/applications/$OBJECT_ID"
azure rest --method PATCH --url "$APPLICATION_URL" --headers Content-Type=application/json --body "$PATCH" -o none
SPS=$(azure ad sp list --filter "appId eq '$APP_ID'" -o json)
COUNT=$(jq 'length' <<< "$SPS")
[[ "$COUNT" -le 1 ]] || { echo 'Multiple service principals found for the gateway application.' >&2; exit 1; }
if [[ "$COUNT" -eq 0 ]]; then
  SP=$(azure ad sp create --id "$APP_ID" -o json)
else
  SP=$(jq -c '.[0]' <<< "$SPS")
fi
VERIFIED=$(azure ad app show --id "$APP_ID" -o json)
jq -e --argjson desired "$PATCH" 'contains($desired)' <<< "$VERIFIED" >/dev/null || {
  echo 'Gateway registration read-back verification failed. Directory propagation may be pending; rerun safely.' >&2; exit 1;
}
SP_ID=$(jq -er .id <<< "$SP")
azure ad sp show --id "$SP_ID" -o json |
  jq -e --arg app "$APP_ID" --arg id "$SP_ID" '.appId == $app and .id == $id' >/dev/null || {
    echo 'Gateway service principal read-back verification failed.' >&2; exit 1;
  }
jq --arg tenant "$TENANT_ID" --arg sp "$SP_ID" '{
  tenantId: $tenant, gatewayAudience: .appId, tokenResource: ("api://" + .appId),
  applicationObjectId: .id, servicePrincipalObjectId: $sp,
  roles: [.appRoles[] | {value, id, allowedMemberTypes, isEnabled}]
}' <<< "$VERIFIED"
