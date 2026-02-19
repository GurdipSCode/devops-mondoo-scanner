#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches .buildkite/scan-config.yaml from a product's policy repo.

.DESCRIPTION
    Each devops-configs-policies-{tool} repo owns its scan targets and
    Buildkite variables in .buildkite/scan-config.yaml. This script
    pulls that file via the GitHub API so mondoo-runner knows what to scan.

.PARAMETER Tool
    Tool name (e.g. vault, buildkite, lynx).

.PARAMETER Org
    GitHub organisation. Default: GurdipSCode.

.PARAMETER Ref
    Git ref to fetch from. Default: main.

.EXAMPLE
    .\Get-ScanConfig.ps1 -Tool vault
    .\Get-ScanConfig.ps1 -Tool lynx -Ref v1.2.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Tool,

    [string]$Org = "GurdipSCode",

    [string]$Ref = "main"
)

$ErrorActionPreference = "Stop"

$repo = "devops-configs-policies-$Tool"
$outputDir = Join-Path $env:TEMP "mondoo-scan-config"
$outputFile = Join-Path $outputDir "$Tool.yaml"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Write-Host "--- :gear: Fetching scan-config for $Tool" -ForegroundColor Cyan
Write-Host "Repo: $Org/$repo@$Ref"

$token = $env:POLICY_REPO_TOKEN
if (-not $token) {
    try {
        $token = & buildkite-agent secret get POLICY_REPO_TOKEN 2>$null
    } catch {
        Write-Error "POLICY_REPO_TOKEN not available. Set it as env var or Buildkite secret."
        exit 1
    }
}

$uri = "https://api.github.com/repos/$Org/$repo/contents/.buildkite/scan-config.yaml?ref=$Ref"
$headers = @{
    Authorization = "token $token"
    Accept        = "application/vnd.github.v3.raw"
    "User-Agent"  = "mondoo-runner"
}

try {
    $response = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing
    [System.IO.File]::WriteAllBytes($outputFile, $response.Content)
    Write-Host "Fetched scan-config.yaml -> $outputFile" -ForegroundColor Green
} catch {
    $status = $_.Exception.Response.StatusCode.value__
    Write-Error "Failed to fetch scan-config.yaml from $Org/$repo (HTTP $status)"
    Write-Error "Ensure .buildkite/scan-config.yaml exists in the repo"
    exit 1
}

# Validate it's parseable YAML
try {
    # Use yq to validate if available, otherwise just check it's not empty
    if (Get-Command yq -ErrorAction SilentlyContinue) {
        $toolName = & yq ".tool" $outputFile
        Write-Host "Validated: tool=$toolName" -ForegroundColor Green
    }
} catch {
    Write-Warning "Could not validate YAML (yq not found) — proceeding anyway"
}

return $outputFile
