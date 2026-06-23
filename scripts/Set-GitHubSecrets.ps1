<#
.SYNOPSIS
    Pushes the FABRIC_* values from a .env file to a GitHub repository as Actions secrets, and
    creates the test/prod GitHub Environments.

.DESCRIPTION
    Requires the GitHub CLI (gh) authenticated with repo admin rights (`gh auth login`).
    Run Setup-FabricPocEnvironment.ps1 first to generate the .env, then fill in FABRIC_CLIENT_ID and
    FABRIC_CLIENT_SECRET from your service principal before running this.

.EXAMPLE
    ./scripts/Set-GitHubSecrets.ps1 -Repo "your-org/fabric-schedule-rehydration-poc"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Repo,
    [string] $EnvFilePath = ".env",
    [switch] $SkipEnvironments
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path $EnvFilePath)) {
    throw ".env file not found: $EnvFilePath. Run ./scripts/Setup-FabricPocEnvironment.ps1 first."
}

# Parse .env into an ordered map.
$pairs = [ordered]@{}
foreach ($line in Get-Content $EnvFilePath) {
    if ($line -match '^\s*#' -or [string]::IsNullOrWhiteSpace($line)) { continue }
    $k, $v = $line -split '=', 2
    if ($k) { $pairs[$k.Trim()] = ($(if ($null -ne $v) { $v } else { '' })).Trim() }
}

# Create GitHub Environments used by the workflow's approval gates.
if (-not $SkipEnvironments) {
    foreach ($envName in 'test', 'prod') {
        gh api -X PUT "repos/$Repo/environments/$envName" --silent
        if ($LASTEXITCODE -eq 0) { Write-Host "Environment '$envName' ensured." }
        else { Write-Host "WARNING: could not create environment '$envName' (exit $LASTEXITCODE)." }
    }
}

# Push every non-empty FABRIC_* value as a repository secret.
$set = 0
$skipped = @()
foreach ($k in $pairs.Keys) {
    if ($k -notlike 'FABRIC_*') { continue }
    if ([string]::IsNullOrWhiteSpace($pairs[$k])) { $skipped += $k; continue }
    gh secret set $k --repo $Repo --body $pairs[$k] | Out-Null
    if ($LASTEXITCODE -eq 0) { Write-Host "Set secret $k"; $set++ }
    else { Write-Host "WARNING: failed to set secret $k (exit $LASTEXITCODE)." }
}

Write-Host ""
Write-Host "Done. $set secret(s) set on $Repo."
if ($skipped.Count -gt 0) {
    Write-Host "Skipped (empty in $EnvFilePath): $($skipped -join ', ')"
    Write-Host "Fill these in and re-run, especially FABRIC_CLIENT_ID and FABRIC_CLIENT_SECRET."
}
