#requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Guid]$TenantId,
    [ValidateNotNullOrEmpty()][string]$DisplayName = 'Claude Gateway API',
    [Guid]$AppId = [Guid]::Empty,
    [switch]$DryRun,
    [switch]$Yes
)
$ErrorActionPreference = 'Stop'

function Invoke-Azure {
    $Arguments = $args
    $Result = & az @Arguments --only-show-errors
    if ($LASTEXITCODE -ne 0) {
        throw "Azure CLI failed: $($Arguments[0..([Math]::Min(2, $Arguments.Length - 1))] -join ' '). Resolve the error and rerun; directory objects are not automatically deleted."
    }
    return $Result
}

if ($DryRun) {
    $Target = if ($AppId -ne [Guid]::Empty) { $AppId } else { $DisplayName }
    Write-Output "DRY RUN: tenant=$TenantId; gateway=$Target. Ensure API registration, service principal, v2 tokens, access_as_user and Claude.User/Claude.Tier.Pro/Claude.Tier.Basic/Claude.Suspended. No Azure calls or writes."
    return
}
if (-not $Yes) { throw 'Review -DryRun, then pass -Yes to authorize Entra changes.' }
Get-Command az, jq -ErrorAction Stop | Out-Null
$Account = Invoke-Azure account show -o json | ConvertFrom-Json
if ($Account.tenantId -ne $TenantId.ToString()) {
    throw 'Wrong Azure tenant. Run az login --tenant <tenant-id> and retry.'
}
if ($AppId -ne [Guid]::Empty) {
    $Application = Invoke-Azure ad app show --id $AppId.ToString() -o json | ConvertFrom-Json -AsHashtable
} else {
    $Applications = @(Invoke-Azure ad app list --display-name $DisplayName -o json | ConvertFrom-Json -AsHashtable)
    $Applications = @($Applications | Where-Object { $_.displayName -ceq $DisplayName })
    if ($Applications.Count -gt 1) { throw 'Multiple exact-name applications found. Specify -AppId.' }
    if ($Applications.Count -eq 1) {
        $Application = $Applications[0]
    } else {
        $Application = Invoke-Azure ad app create --display-name $DisplayName --sign-in-audience AzureADMyOrg -o json | ConvertFrom-Json -AsHashtable
    }
}
if ($Application.signInAudience -ne 'AzureADMyOrg') {
    throw 'The existing registration must be single-tenant (AzureADMyOrg).'
}
$ClientId = $Application.appId
$ObjectId = $Application.id
$Roles = @(
    foreach ($Value in 'Claude.User', 'Claude.Tier.Pro', 'Claude.Tier.Basic', 'Claude.Suspended') {
        @{
            id = [Guid]::NewGuid().ToString()
            value = $Value
            displayName = $Value
            description = "Claude gateway role: $Value"
            allowedMemberTypes = @('User')
            isEnabled = $true
        }
    }
)
$RolesJson = ConvertTo-Json -InputObject $Roles -Depth 10 -Compress
$Patch = $Application | ConvertTo-Json -Depth 50 -Compress |
    & jq -ce --arg scopeId ([Guid]::NewGuid().ToString()) --argjson roles $RolesJson `
        -f (Join-Path $PSScriptRoot 'gateway-app-registration.jq')
if ($LASTEXITCODE -ne 0) { throw 'Could not build the gateway application configuration.' }
Invoke-Azure rest --method PATCH --url "https://graph.microsoft.com/v1.0/applications/$ObjectId" `
    --headers Content-Type=application/json --body $Patch -o none | Out-Null
$ServicePrincipals = @(Invoke-Azure ad sp list --filter "appId eq '$ClientId'" -o json | ConvertFrom-Json -AsHashtable)
if ($ServicePrincipals.Count -gt 1) { throw 'Multiple service principals found for the gateway application.' }
if ($ServicePrincipals.Count -eq 0) {
    $ServicePrincipal = Invoke-Azure ad sp create --id $ClientId -o json | ConvertFrom-Json -AsHashtable
} else {
    $ServicePrincipal = $ServicePrincipals[0]
}
$VerifiedJson = Invoke-Azure ad app show --id $ClientId -o json
$VerifiedJson | & jq -e --argjson desired $Patch 'contains($desired)' | Out-Null
if ($LASTEXITCODE -ne 0) {
    throw 'Gateway registration read-back verification failed. Directory propagation may be pending; rerun safely.'
}
$VerifiedPrincipal = Invoke-Azure ad sp show --id $ServicePrincipal.id -o json | ConvertFrom-Json -AsHashtable
if ($VerifiedPrincipal.appId -ne $ClientId -or $VerifiedPrincipal.id -ne $ServicePrincipal.id) {
    throw 'Gateway service principal read-back verification failed.'
}
$Verified = $VerifiedJson | ConvertFrom-Json -AsHashtable
@{
    tenantId = $TenantId.ToString()
    gatewayAudience = $ClientId
    tokenResource = "api://$ClientId"
    applicationObjectId = $ObjectId
    servicePrincipalObjectId = $ServicePrincipal.id
    roles = @($Verified.appRoles | ForEach-Object {
        @{ value = $_.value; id = $_.id; allowedMemberTypes = $_.allowedMemberTypes; isEnabled = $_.isEnabled }
    })
} | ConvertTo-Json -Depth 10
