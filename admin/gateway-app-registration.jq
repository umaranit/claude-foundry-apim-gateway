.identifierUris = ((.identifierUris // []) + [("api://" + .appId)] | unique) |
.api = ((.api // {}) + {requestedAccessTokenVersion: 2}) |
.api.oauth2PermissionScopes = (
  (.api.oauth2PermissionScopes // []) |
  if any(.[]; .value == "access_as_user") then
    map(if .value == "access_as_user" then . + {isEnabled: true} else . end)
  else
    . + [{
      id: $scopeId, value: "access_as_user", type: "User", isEnabled: true,
      adminConsentDisplayName: "Access Claude Gateway",
      adminConsentDescription: "Access the Claude gateway as the signed-in user",
      userConsentDisplayName: "Access Claude Gateway",
      userConsentDescription: "Access the Claude gateway as you"
    }]
  end
) |
.appRoles = (
  reduce $roles[] as $role ((.appRoles // []);
    if any(.[]; .value == $role.value) then
      map(if .value == $role.value then
        . + {isEnabled: true, allowedMemberTypes: ((.allowedMemberTypes // []) + ["User"] | unique)}
      else . end)
    else . + [$role] end
  )
) |
{identifierUris, api, appRoles}
