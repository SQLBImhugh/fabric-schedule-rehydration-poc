<#
.SYNOPSIS
    Triggers a Microsoft Fabric Deployment Pipeline stage promotion (Deploy Stage Content API)
    and waits for the long-running operation to finish.

.DESCRIPTION
    Promotes content from a source stage to a target stage (e.g. DEV -> TEST or TEST -> PROD).
    Schedules are NOT promoted by this step on purpose; they are reapplied afterwards by
    Set-FabricItemSchedules.ps1 from the GitHub-owned schedule policy.

.EXAMPLE
    ./scripts/Deploy-FabricStage.ps1 `
        -TenantId $env:FABRIC_TENANT_ID `
        -ClientId $env:FABRIC_CLIENT_ID `
        -ClientSecret $env:FABRIC_CLIENT_SECRET `
        -DeploymentPipelineId $env:FABRIC_DEPLOYMENT_PIPELINE_ID `
        -SourceStageId $env:FABRIC_DEV_STAGE_ID `
        -TargetStageId $env:FABRIC_TEST_STAGE_ID `
        -Note "Local POC DEV to TEST deployment"
#>
param(
    [Parameter(Mandatory = $true)] [string] $TenantId,
    [Parameter(Mandatory = $true)] [string] $ClientId,
    [Parameter(Mandatory = $true)] [string] $ClientSecret,
    [Parameter(Mandatory = $true)] [string] $DeploymentPipelineId,
    [Parameter(Mandatory = $true)] [string] $SourceStageId,
    [Parameter(Mandatory = $true)] [string] $TargetStageId,
    [Parameter(Mandatory = $false)] [string] $Note = "GitHub Actions deployment"
)

$ErrorActionPreference = "Stop"

. "$PSScriptRoot/Get-FabricToken.ps1"
. "$PSScriptRoot/Invoke-FabricApi.ps1"

Write-Host "=== Fabric Deployment Pipeline promotion ==="
Write-Host "Deployment pipeline : $DeploymentPipelineId"
Write-Host "Source stage        : $SourceStageId"
Write-Host "Target stage        : $TargetStageId"
Write-Host "Note                : $Note"

$token = Get-FabricAccessToken -TenantId $TenantId -ClientId $ClientId -ClientSecret $ClientSecret

$uri  = "https://api.fabric.microsoft.com/v1/deploymentPipelines/$DeploymentPipelineId/deploy"
$body = @{
    sourceStageId = $SourceStageId
    targetStageId = $TargetStageId
    note          = $Note
}

$response = Invoke-FabricRequest -Method POST -Uri $uri -Token $token -Body $body
$statusCode = [int]$response.StatusCode
Write-Host "Deploy request returned HTTP $statusCode."

if ($statusCode -eq 200) {
    Write-Host "Deployment completed synchronously."
}
else {
    $operationUrl = $response.Headers['Location']
    if ($operationUrl -is [array]) { $operationUrl = $operationUrl[0] }
    Write-Host "Polling long-running operation: $operationUrl"
    $op = Wait-FabricLongRunningOperation -Token $token -OperationUrl $operationUrl
    Write-Host "Deployment operation finished with status: $($op.status)"
}

Write-Host "=== Deployment succeeded ==="
