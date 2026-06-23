<#
.SYNOPSIS
    Convenience helper for the demo: prints the current schedules of every item declared for an
    environment. Use it to show "before vs after" schedule state in the demo walkthrough.

.EXAMPLE
    ./scripts/Show-FabricItemSchedules.ps1 `
        -TenantId $env:FABRIC_TENANT_ID `
        -ClientId $env:FABRIC_CLIENT_ID `
        -ClientSecret $env:FABRIC_CLIENT_SECRET `
        -Environment "test" `
        -ConfigPath "./config/fabric-schedules.json"
#>
param(
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $true)] [string] $ClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecret,
    [Parameter(Mandatory = $true)] [ValidateSet("dev", "test", "prod")] [string] $Environment,
    [Parameter(Mandatory = $true)] [string] $ConfigPath
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Get-FabricToken.ps1"
. "$PSScriptRoot/Invoke-FabricApi.ps1"

if (-not (Test-Path $ConfigPath)) { throw "Config file not found: $ConfigPath" }
$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
$environmentConfig = $config.environments.$Environment
$workspaceId = Resolve-FabricWorkspaceId -Environment $Environment

$token = Get-FabricAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
$base  = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId"

Write-Host "=== Current schedules for environment: $Environment (workspace $workspaceId) ==="
foreach ($item in $environmentConfig.items) {
    $itemKey = if ([string]::IsNullOrWhiteSpace($item.itemKey)) { "PIPELINE" } else { $item.itemKey }
    $jobType = if ([string]::IsNullOrWhiteSpace($item.jobType)) { "Pipeline" } else { $item.jobType }
    $itemId  = Resolve-FabricItemId -Environment $Environment -ItemKey $itemKey
    Write-Host ""
    Write-Host "--- $($item.name) ($itemId) ---"
    $result = Invoke-FabricApi -Method GET -Uri "$base/items/$itemId/jobs/$jobType/schedules" -Token $token
    $schedules = if ($null -ne $result -and $result.PSObject.Properties.Name -contains "value") { @($result.value) } else { @($result) }
    if ($schedules.Count -eq 0 -or $null -eq $schedules[0]) {
        Write-Host "  (no schedules - disabled)"
        continue
    }
    foreach ($s in $schedules) {
        Write-Host "  id=$($s.id) enabled=$($s.enabled) type=$($s.configuration.type)"
        Write-Host "     $($s.configuration | ConvertTo-Json -Depth 8 -Compress)"
    }
}
