<#
.SYNOPSIS
    One-time provisioning of the Fabric objects this POC needs, then emits the IDs required for the
    GitHub secrets (and writes them to a .env file). Designed so a customer can replicate the whole
    setup in their own tenant with a single command.

.DESCRIPTION
    Idempotent: existing workspaces / deployment pipeline / data pipeline are reused by display name;
    anything missing is created. Optionally grants a service principal Admin on the three workspaces
    and the deployment pipeline. By default it authenticates with your current Azure CLI login
    (az account get-access-token); pass -AccessToken to use a token you already hold.

    What it provisions:
      - DEV / TEST / PROD workspaces (on the given capacity)
      - A simple Data Pipeline in DEV (Wait activity + an "Environment" parameter)
      - A Deployment Pipeline with Development / Test / Production stages, each assigned to a workspace
      - (optional) An initial DEV -> TEST -> PROD deployment so every stage has the item
      - (optional) Admin role assignments for a service principal

.PARAMETER CapacityName
    Display name of the Fabric capacity to host the workspaces (e.g. "Trial-East"). Provide this or
    -CapacityId when any workspace has to be created.

.PARAMETER ServicePrincipalObjectId
    Object ID (enterprise-app object ID) of the service principal GitHub Actions will use. When set,
    the script grants it Admin on the workspaces and the deployment pipeline.

.EXAMPLE
    az login
    ./scripts/Setup-FabricPocEnvironment.ps1 -CapacityName "Trial-East" -ServicePrincipalObjectId <sp-object-id>
#>
[CmdletBinding()]
param(
    [string] $CapacityName,
    [string] $CapacityId,
    [string] $DevWorkspaceName      = "Github_Dev",
    [string] $TestWorkspaceName     = "Github_Test",
    [string] $ProdWorkspaceName     = "Github_Prod",
    [string] $DeploymentPipelineName = "Schedule Rehydration POC",
    [string] $DataPipelineName      = "POC_Demo_Pipeline",
    [string] $ServicePrincipalObjectId,
    [string] $TenantId,
    [string] $AccessToken,
    [string] $EnvFilePath = ".env",
    [switch] $SkipInitialDeploy
)

$ErrorActionPreference = "Stop"
. "$PSScriptRoot/Invoke-FabricApi.ps1"

$fabric = "https://api.fabric.microsoft.com/v1"

# ---------------------------------------------------------------------------
# Token + tenant
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($AccessToken)) {
    Write-Host "Acquiring a Fabric token via Azure CLI (az account get-access-token)..."
    $AccessToken = (az account get-access-token --resource "https://api.fabric.microsoft.com" --query accessToken -o tsv)
    if ([string]::IsNullOrWhiteSpace($AccessToken)) {
        throw "Could not acquire a token from Azure CLI. Run 'az login' first, or pass -AccessToken."
    }
}
if ([string]::IsNullOrWhiteSpace($TenantId)) {
    try { $TenantId = (az account show --query tenantId -o tsv) } catch { }
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
function Resolve-Capacity {
    if (-not [string]::IsNullOrWhiteSpace($script:CapacityId)) { return }
    if ([string]::IsNullOrWhiteSpace($CapacityName)) {
        throw "A workspace must be created but neither -CapacityId nor -CapacityName was provided."
    }
    $caps = Invoke-FabricApi -Method GET -Uri "$fabric/capacities" -Token $AccessToken
    $cap = @($caps.value) | Where-Object { $_.displayName -eq $CapacityName } | Select-Object -First 1
    if (-not $cap) { throw "Capacity '$CapacityName' not found or not visible to you." }
    $script:CapacityId = $cap.id
    Write-Host "Using capacity '$CapacityName' ($($cap.id))."
}

function Get-WorkspaceByName([string] $Name) {
    $all = Invoke-FabricApi -Method GET -Uri "$fabric/workspaces" -Token $AccessToken
    return @($all.value) | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function Get-OrCreateWorkspace([string] $Name) {
    $ws = Get-WorkspaceByName $Name
    if ($ws) { Write-Host "  Workspace '$Name' exists ($($ws.id))."; return $ws.id }
    Resolve-Capacity
    $body = @{ displayName = $Name; capacityId = $script:CapacityId }
    $created = Invoke-FabricApi -Method POST -Uri "$fabric/workspaces" -Token $AccessToken -Body $body
    Write-Host "  Created workspace '$Name' ($($created.id))."
    return $created.id
}

function Get-ItemByName([string] $WorkspaceId, [string] $Name, [string] $Type) {
    $items = Invoke-FabricApi -Method GET -Uri "$fabric/workspaces/$WorkspaceId/items" -Token $AccessToken
    return @($items.value) | Where-Object { $_.displayName -eq $Name -and $_.type -eq $Type } | Select-Object -First 1
}

function Get-OrCreateDataPipeline([string] $WorkspaceId, [string] $Name) {
    $existing = Get-ItemByName $WorkspaceId $Name "DataPipeline"
    if ($existing) { Write-Host "  Data pipeline '$Name' exists ($($existing.id))."; return $existing.id }

    $content = @{
        properties = @{
            activities = @( @{ name = "WaitActivity"; type = "Wait"; dependsOn = @(); typeProperties = @{ waitTimeInSeconds = 5 } } )
            parameters = @{ Environment = @{ type = "string"; defaultValue = "DEV" } }
        }
    } | ConvertTo-Json -Depth 25
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
    $body = @{
        displayName = $Name
        type        = "DataPipeline"
        description = "POC demo data pipeline (Wait activity). Schedule behavior is the demo point."
        definition  = @{ parts = @( @{ path = "pipeline-content.json"; payload = $b64; payloadType = "InlineBase64" } ) }
    }
    $created = Invoke-FabricApi -Method POST -Uri "$fabric/workspaces/$WorkspaceId/items" -Token $AccessToken -Body $body
    Write-Host "  Created data pipeline '$Name' ($($created.id))."
    return $created.id
}

function Get-DeploymentPipelineByName([string] $Name) {
    $all = Invoke-FabricApi -Method GET -Uri "$fabric/deploymentPipelines" -Token $AccessToken
    return @($all.value) | Where-Object { $_.displayName -eq $Name } | Select-Object -First 1
}

function Grant-Admin([string] $Uri, [string] $PrincipalId) {
    $body = @{ principal = @{ id = $PrincipalId; type = "ServicePrincipal" }; role = "Admin" }
    try {
        Invoke-FabricApi -Method POST -Uri $Uri -Token $AccessToken -Body $body | Out-Null
        Write-Host "    granted Admin -> $Uri"
    }
    catch {
        Write-Host "    (role assignment skipped for $Uri - likely already granted)"
    }
}

function Invoke-StageDeploy([string] $PipelineId, [string] $SourceStageId, [string] $TargetStageId, [string] $Note) {
    $body = @{ sourceStageId = $SourceStageId; targetStageId = $TargetStageId; note = $Note }
    $resp = Invoke-FabricRequest -Method POST -Uri "$fabric/deploymentPipelines/$PipelineId/deploy" -Token $AccessToken -Body $body
    if ([int]$resp.StatusCode -eq 200) { Write-Host "    $Note -> completed"; return }
    $op = $resp.Headers['Location']; if ($op -is [array]) { $op = $op[0] }
    $result = Wait-FabricLongRunningOperation -Token $AccessToken -OperationUrl $op
    Write-Host "    $Note -> $($result.status)"
}

# ---------------------------------------------------------------------------
# 1) Workspaces
# ---------------------------------------------------------------------------
Write-Host "=== Workspaces ==="
$devWs  = Get-OrCreateWorkspace $DevWorkspaceName
$testWs = Get-OrCreateWorkspace $TestWorkspaceName
$prodWs = Get-OrCreateWorkspace $ProdWorkspaceName

# ---------------------------------------------------------------------------
# 2) Data pipeline in DEV
# ---------------------------------------------------------------------------
Write-Host "=== Data pipeline (DEV) ==="
$devItem = Get-OrCreateDataPipeline $devWs $DataPipelineName

# ---------------------------------------------------------------------------
# 3) Deployment pipeline + stages
# ---------------------------------------------------------------------------
Write-Host "=== Deployment pipeline ==="
$dp = Get-DeploymentPipelineByName $DeploymentPipelineName
if (-not $dp) {
    $body = @{
        displayName = $DeploymentPipelineName
        description = "Promotes $DataPipelineName DEV->TEST->PROD. Schedules rehydrated post-deploy from a GitHub-owned policy."
        stages = @(
            @{ displayName = "Development"; description = "DEV";  isPublic = $false }
            @{ displayName = "Test";        description = "TEST"; isPublic = $false }
            @{ displayName = "Production";  description = "PROD"; isPublic = $true }
        )
    }
    $dp = Invoke-FabricApi -Method POST -Uri "$fabric/deploymentPipelines" -Token $AccessToken -Body $body
    Write-Host "  Created deployment pipeline '$DeploymentPipelineName' ($($dp.id))."
}
else {
    Write-Host "  Deployment pipeline '$DeploymentPipelineName' exists ($($dp.id))."
}

$stages = @(Invoke-FabricApi -Method GET -Uri "$fabric/deploymentPipelines/$($dp.id)/stages" -Token $AccessToken).value | Sort-Object order
$stageMap = @{ 0 = $devWs; 1 = $testWs; 2 = $prodWs }
foreach ($stage in $stages) {
    $targetWs = $stageMap[[int]$stage.order]
    if ([string]::IsNullOrWhiteSpace($stage.workspaceId)) {
        Invoke-FabricApi -Method POST -Uri "$fabric/deploymentPipelines/$($dp.id)/stages/$($stage.id)/assignWorkspace" -Token $AccessToken -Body @{ workspaceId = $targetWs } | Out-Null
        Write-Host "  Assigned stage '$($stage.displayName)' -> $targetWs"
    }
    elseif ($stage.workspaceId -ne $targetWs) {
        Write-Host "  WARNING: stage '$($stage.displayName)' is assigned to $($stage.workspaceId), expected $targetWs."
    }
}
$devStage  = ($stages | Where-Object order -eq 0).id
$testStage = ($stages | Where-Object order -eq 1).id
$prodStage = ($stages | Where-Object order -eq 2).id

# ---------------------------------------------------------------------------
# 4) Service principal grants (optional)
# ---------------------------------------------------------------------------
if (-not [string]::IsNullOrWhiteSpace($ServicePrincipalObjectId)) {
    Write-Host "=== Granting service principal Admin ==="
    foreach ($ws in @($devWs, $testWs, $prodWs)) {
        Grant-Admin "$fabric/workspaces/$ws/roleAssignments" $ServicePrincipalObjectId
    }
    Grant-Admin "$fabric/deploymentPipelines/$($dp.id)/roleAssignments" $ServicePrincipalObjectId
}

# ---------------------------------------------------------------------------
# 5) Initial deploy (optional) + capture TEST/PROD item IDs
# ---------------------------------------------------------------------------
if (-not $SkipInitialDeploy) {
    Write-Host "=== Initial deployment DEV -> TEST -> PROD ==="
    Invoke-StageDeploy $dp.id $devStage  $testStage "Initial DEV to TEST"
    Invoke-StageDeploy $dp.id $testStage $prodStage "Initial TEST to PROD"
}

$testItemObj = Get-ItemByName $testWs $DataPipelineName "DataPipeline"
$prodItemObj = Get-ItemByName $prodWs $DataPipelineName "DataPipeline"
$testItem = if ($testItemObj) { $testItemObj.id } else { "" }
$prodItem = if ($prodItemObj) { $prodItemObj.id } else { "" }
if (-not $testItem) { Write-Host "NOTE: $DataPipelineName not found in TEST yet (deploy first to populate it)." }
if (-not $prodItem) { Write-Host "NOTE: $DataPipelineName not found in PROD yet (deploy first to populate it)." }

# ---------------------------------------------------------------------------
# 6) Emit results + write .env (merging, preserving client id/secret)
# ---------------------------------------------------------------------------
$values = [ordered]@{
    FABRIC_TENANT_ID              = $TenantId
    FABRIC_DEPLOYMENT_PIPELINE_ID = $dp.id
    FABRIC_DEV_STAGE_ID           = $devStage
    FABRIC_TEST_STAGE_ID          = $testStage
    FABRIC_PROD_STAGE_ID          = $prodStage
    FABRIC_DEV_WORKSPACE_ID       = $devWs
    FABRIC_TEST_WORKSPACE_ID      = $testWs
    FABRIC_PROD_WORKSPACE_ID      = $prodWs
    FABRIC_DEV_PIPELINE_ITEM_ID   = $devItem
    FABRIC_TEST_PIPELINE_ITEM_ID  = $testItem
    FABRIC_PROD_PIPELINE_ITEM_ID  = $prodItem
}

$existing = [ordered]@{}
if (Test-Path $EnvFilePath) {
    foreach ($line in Get-Content $EnvFilePath) {
        if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
        $k, $v = $line -split '=', 2
        if ($k) { $existing[$k.Trim()] = ($(if ($null -ne $v) { $v } else { '' })).Trim() }
    }
}
foreach ($k in 'FABRIC_CLIENT_ID', 'FABRIC_CLIENT_SECRET') {
    if (-not $existing.Contains($k)) { $existing[$k] = '' }
}
foreach ($k in $values.Keys) { if ($values[$k]) { $existing[$k] = $values[$k] } }
$lines = $existing.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }
Set-Content -Path $EnvFilePath -Value $lines -Encoding utf8

Write-Host ""
Write-Host "=== Provisioning complete. IDs written to $EnvFilePath ==="
Write-Host "Set the following GitHub secrets (FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET come from your service principal):"
foreach ($k in $values.Keys) { Write-Host ("  {0,-30} {1}" -f $k, $values[$k]) }
Write-Host ""
Write-Host "Next: fill FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET in $EnvFilePath, then run ./scripts/Set-GitHubSecrets.ps1 -Repo <owner>/<repo>."
