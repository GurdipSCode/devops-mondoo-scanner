#Requires -Version 5.1
<#
.SYNOPSIS
    Fetches MQL policy bundles from a tool's dedicated policy repo.

.PARAMETER Tool
    Tool name (e.g. vault, buildkite, lynx).

.PARAMETER Org
    GitHub organisation. Default: GurdipSCode.

.PARAMETER Ref
    Git ref. Default: main.

.EXAMPLE
    .\Pull-Policies.ps1 -Tool vault
    .\Pull-Policies.ps1 -Tool lynx -Ref v1.3.0
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
$outputDir = Join-Path $env:TEMP "mondoo-policies\$Tool"

New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

Write-Host "--- :git: Pulling MQL policies for $Tool" -ForegroundColor Cyan
Write-Host "Repo: $Org/$repo@$Ref"

$token = $env:POLICY_REPO_TOKEN
if (-not $token) {
    try { $token = & buildkite-agent secret get POLICY_REPO_TOKEN 2>$null } catch {}
}
if (-not $token) {
    Write-Error "POLICY_REPO_TOKEN not available"
    exit 1
}

$headers = @{
    Authorization = "token $token"
    Accept        = "application/json"
    "User-Agent"  = "mondoo-runner"
}

# List files in the policies/ directory
$uri = "https://api.github.com/repos/$Org/$repo/contents/policies?ref=$Ref"

try {
    $files = Invoke-RestMethod -Uri $uri -Headers $headers
} catch {
    # Fallback: try root directory for .mql.yaml files
    Write-Warning "No policies/ directory found, checking root..."
    $uri = "https://api.github.com/repos/$Org/$repo/contents/?ref=$Ref"
    $files = Invoke-RestMethod -Uri $uri -Headers $headers
}

$mqlFiles = $files | Where-Object { $_.name -like "*.mql.yaml" }

if ($mqlFiles.Count -eq 0) {
    Write-Error "No .mql.yaml files found in $Org/$repo@$Ref"
    exit 1
}

# Download each MQL file
$rawHeaders = @{
    Authorization = "token $token"
    Accept        = "application/vnd.github.v3.raw"
    "User-Agent"  = "mondoo-runner"
}

foreach ($file in $mqlFiles) {
    $outPath = Join-Path $outputDir $file.name
    Write-Host "  Downloading $($file.name)..."
    Invoke-WebRequest -Uri $file.download_url -Headers $rawHeaders -OutFile $outPath -UseBasicParsing
}

$count = (Get-ChildItem -Path $outputDir -Filter "*.mql.yaml").Count
Write-Host "Pulled $count policy file(s) to $outputDir" -ForegroundColor Green

try { & buildkite-agent meta-data set "policy-count-$Tool" "$count" 2>$null } catch {}

return $outputDir
