<#
.SYNOPSIS
    Rehydrates (forcibly resets) the schedules of Fabric items for a target environment from a
    GitHub-owned JSON policy file, using the Fabric Job Scheduler REST APIs.

.DESCRIPTION
    Authoritative / declarative mode: for every item declared for the target environment the script
        1. lists existing schedules,
        2. deletes ALL of them,
        3. recreates exactly the schedules declared in config for that environment.

    Consequence (intentional for the POC): any schedule that exists in Fabric but is NOT declared in
    the config is removed. This makes the target environment deterministic after a Deployment
    Pipeline promotion overwrites/clears schedules.

.EXAMPLE
    ./scripts/Set-FabricItemSchedules.ps1 `
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

if (-not (Test-Path $ConfigPath)) {
    throw "Config file not found: $ConfigPath"
}

$config = Get-Content $ConfigPath -Raw | ConvertFrom-Json
if (-not ($config.environments.PSObject.Properties.Name -contains $Environment)) {
    throw "Environment '$Environment' not found in config: $ConfigPath"
}

$environmentConfig = $config.environments.$Environment

# Tenant-specific IDs are resolved from environment variables / GitHub secrets, never from config.
$workspaceId = Resolve-FabricWorkspaceId -Environment $Environment

$token = Get-FabricAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret
$base  = "https://api.fabric.microsoft.com/v1/workspaces/$workspaceId"

Write-Host "=== Schedule rehydration for environment: $Environment ==="
Write-Host "Target workspace: $workspaceId"

foreach ($item in $environmentConfig.items) {
    $itemName = $item.name
    $itemKey  = if ([string]::IsNullOrWhiteSpace($item.itemKey)) { "PIPELINE" } else { $item.itemKey }
    $jobType  = if ([string]::IsNullOrWhiteSpace($item.jobType)) { "Pipeline" } else { $item.jobType }
    $itemId   = Resolve-FabricItemId -Environment $Environment -ItemKey $itemKey

    Write-Host ""
    Write-Host "--- Item: $itemName ($itemId) [key $itemKey], jobType: $jobType ---"
    $schedulesUri = "$base/items/$itemId/jobs/$jobType/schedules"

    # 1) List existing schedules.
    $existing = Invoke-FabricApi -Method GET -Uri $schedulesUri -Token $token
    $existingSchedules = @()
    if ($null -ne $existing) {
        if ($existing.PSObject.Properties.Name -contains "value") {
            $existingSchedules = @($existing.value)
        }
        else {
            $existingSchedules = @($existing)
        }
    }
    Write-Host "Existing schedules found: $($existingSchedules.Count)"

    # 2) Delete every existing schedule (authoritative mode).
    foreach ($schedule in $existingSchedules) {
        if ($null -ne $schedule.id) {
            Write-Host "  Deleting schedule $($schedule.id)"
            Invoke-FabricApi -Method DELETE -Uri "$schedulesUri/$($schedule.id)" -Token $token | Out-Null
        }
    }

    # 3) Recreate the schedules declared for this environment.
    $declared = @($item.schedules)
    if ($declared.Count -eq 0) {
        Write-Host "  No schedules declared for '$Environment'. Item left with zero schedules (disabled)."
        continue
    }

    if ($declared.Count -gt 20) {
        throw "Item '$itemName' declares $($declared.Count) schedules; Fabric allows a maximum of 20 per item."
    }

    foreach ($schedule in $declared) {
        $body = @{
            enabled       = [bool] $schedule.enabled
            configuration = $schedule.configuration
        }
        if ($schedule.PSObject.Properties.Name -contains "executionData") {
            $body.executionData = $schedule.executionData
        }
        Write-Host "  Creating $($schedule.configuration.type) schedule (enabled = $($schedule.enabled))"
        Invoke-FabricApi -Method POST -Uri $schedulesUri -Token $token -Body $body | Out-Null
    }
}

Write-Host ""
Write-Host "=== Schedule policy applied successfully for environment: $Environment ==="
