<#
.SYNOPSIS
    Acquires a Microsoft Fabric API access token using a service principal
    (OAuth 2.0 client credentials grant).

.DESCRIPTION
    Dot-source this file to make the Get-FabricAccessToken function available:

        . "$PSScriptRoot/Get-FabricToken.ps1"
        $token = Get-FabricAccessToken -TenantId $t -ClientId $c -ClientSecret $s

    Or run it directly to print a token to stdout:

        ./scripts/Get-FabricToken.ps1 -TenantId $t -ClientId $c -ClientSecret $s

.NOTES
    Never echo the client secret. GitHub Actions masks registered secrets in logs.
#>
function Get-FabricAccessToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $TenantId,
        [Parameter(Mandatory = $true)] [string] $ClientId,
        [Parameter(Mandatory = $true)] [string] $ClientSecret,
        [string] $Scope = "https://api.fabric.microsoft.com/.default"
    )

    $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        grant_type    = "client_credentials"
        scope         = $Scope
    }

    Write-Verbose "Requesting Fabric token from $tokenUri (scope: $Scope)"
    try {
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body `
            -ContentType "application/x-www-form-urlencoded" -ErrorAction Stop
    }
    catch {
        throw "Failed to acquire Fabric token for client ${ClientId}: $($_.Exception.Message) $($_.ErrorDetails.Message)"
    }

    if ([string]::IsNullOrWhiteSpace($response.access_token)) {
        throw "Token endpoint returned an empty access_token."
    }
    return $response.access_token
}

# When executed directly (not dot-sourced), print a token using FABRIC_* environment variables.
# Dot-sourcing sets $MyInvocation.InvocationName to '.', so this block is skipped on import.
if ($MyInvocation.InvocationName -ne '.' -and
    $env:FABRIC_TENANT_ID -and $env:FABRIC_CLIENT_ID -and $env:FABRIC_CLIENT_SECRET) {
    Get-FabricAccessToken -TenantId $env:FABRIC_TENANT_ID -ClientId $env:FABRIC_CLIENT_ID -ClientSecret $env:FABRIC_CLIENT_SECRET
}
