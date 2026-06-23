<#
.SYNOPSIS
    Shared, defensive helpers for calling the Microsoft Fabric REST API.

.DESCRIPTION
    Dot-source this file to make the following functions available:

      - Invoke-FabricRequest             Raw call returning the full web response (headers + content).
                                         Used when the caller needs response headers (e.g. LRO Location).
      - Invoke-FabricApi                 Convenience call returning parsed JSON (or $null when empty).
      - Wait-FabricLongRunningOperation  Polls a long-running-operation URL until it reaches a
                                         terminal state.

    All calls automatically retry on HTTP 429 (throttling) using the Retry-After header when present.
#>

function Invoke-FabricRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet("GET", "POST", "PUT", "PATCH", "DELETE")] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $Token,
        [object] $Body = $null,
        [int] $MaxRetries = 5
    )

    $headers = @{ Authorization = "Bearer $Token" }
    $attempt = 0

    while ($true) {
        $attempt++
        try {
            $params = @{
                Method      = $Method
                Uri         = $Uri
                Headers     = $headers
                ErrorAction = "Stop"
            }
            if ($null -ne $Body) {
                $params.Body = if ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 100 }
                $params.ContentType = "application/json"
            }
            return Invoke-WebRequest @params
        }
        catch {
            $status = $null
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }

            if ($status -eq 429 -and $attempt -le $MaxRetries) {
                $retryAfter = 10
                try { $retryAfter = [int]$_.Exception.Response.Headers['Retry-After'] } catch { }
                if ($retryAfter -le 0) { $retryAfter = 10 }
                Write-Host "  HTTP 429 (throttled). Waiting $retryAfter s then retrying (attempt $attempt/$MaxRetries)."
                Start-Sleep -Seconds $retryAfter
                continue
            }

            throw "Fabric API $Method $Uri failed (HTTP $status): $($_.Exception.Message) $($_.ErrorDetails.Message)"
        }
    }
}

function Invoke-FabricApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [ValidateSet("GET", "POST", "PUT", "PATCH", "DELETE")] [string] $Method,
        [Parameter(Mandatory = $true)] [string] $Uri,
        [Parameter(Mandatory = $true)] [string] $Token,
        [object] $Body = $null,
        [int] $MaxRetries = 5
    )

    $response = Invoke-FabricRequest -Method $Method -Uri $Uri -Token $Token -Body $Body -MaxRetries $MaxRetries
    if ($null -eq $response -or [string]::IsNullOrWhiteSpace($response.Content)) {
        return $null
    }
    return $response.Content | ConvertFrom-Json
}

function Wait-FabricLongRunningOperation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Token,
        [string] $OperationUrl,
        [int] $PollSeconds = 8,
        [int] $TimeoutMinutes = 30
    )

    if ([string]::IsNullOrWhiteSpace($OperationUrl)) {
        Write-Host "  No long-running-operation URL returned; nothing to poll."
        return $null
    }

    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ($true) {
        if ((Get-Date) -gt $deadline) {
            throw "Timed out after $TimeoutMinutes minutes waiting for operation to complete."
        }
        Start-Sleep -Seconds $PollSeconds

        $op = Invoke-FabricApi -Method GET -Uri $OperationUrl -Token $Token
        if ($null -eq $op) { continue }

        Write-Host "  operation status: $($op.status)"
        switch ($op.status) {
            "Succeeded" { return $op }
            "Completed" { return $op }
            "Failed"    { throw "Operation failed: $($op | ConvertTo-Json -Depth 12)" }
            "Canceled"  { throw "Operation was canceled." }
            default     { } # NotStarted / Running -> keep polling
        }
    }
}

function Get-RequiredEnvValue {
    # Reads a required environment variable (GitHub secret passed via 'env:' or a local .env value).
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Name)

    $value = [Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        throw "Required environment variable '$Name' is not set. Provide it as a GitHub secret (passed via the workflow step 'env:' block) or in your local .env file."
    }
    return $value
}

function Resolve-FabricWorkspaceId {
    # Resolves the workspace ID for an environment from FABRIC_<ENV>_WORKSPACE_ID.
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)] [string] $Environment)
    return Get-RequiredEnvValue "FABRIC_$($Environment.ToUpper())_WORKSPACE_ID"
}

function Resolve-FabricItemId {
    # Resolves an item ID from FABRIC_<ENV>_<ITEMKEY>_ITEM_ID (default item key: PIPELINE).
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)] [string] $Environment,
        [string] $ItemKey = "PIPELINE"
    )
    return Get-RequiredEnvValue "FABRIC_$($Environment.ToUpper())_$($ItemKey.ToUpper())_ITEM_ID"
}
