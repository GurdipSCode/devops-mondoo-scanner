#Requires -Version 5.1
<#
.SYNOPSIS
    Orchestrates the full Mondoo scan lifecycle on Windows.

.DESCRIPTION
    1. Fetch scan-config.yaml from the product's policy repo
    2. Pull MQL policies from the same repo
    3. Pull YAML thresholds from security-config
    4. Merge base + environment overrides
    5. Execute cnspec scan against target(s) defined in scan-config
    6. Report results via Buildkite annotations

.PARAMETER Tool
    Tool name (e.g. vault, buildkite, lynx).

.PARAMETER Environment
    Target environment (production, staging, dev).

.PARAMETER TargetOverride
    Optional single target override (host:port or container name).

.PARAMETER PolicyRef
    Git ref for the policy repo. Default: main.

.PARAMETER ConfigRef
    Git ref for the security-config repo. Default: main.

.PARAMETER Org
    GitHub organisation. Default: GurdipSCode.

.EXAMPLE
    .\Invoke-Scan.ps1 -Tool vault -Environment production
    .\Invoke-Scan.ps1 -Tool buildkite -Environment production -TargetOverride "bk-agent-1.internal:22"
    .\Invoke-Scan.ps1 -Tool lynx -Environment staging -PolicyRef v1.3.0
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$Tool,

    [Parameter(Mandatory)]
    [string]$Environment,

    [string]$TargetOverride = "",

    [string]$PolicyRef = "main",

    [string]$ConfigRef = "main",

    [string]$Org = "GurdipSCode"
)

$ErrorActionPreference = "Stop"
$scriptDir = $PSScriptRoot

# ═══════════════════════════════════════════════════════════════
Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Mondoo Security Scan" -ForegroundColor Cyan
Write-Host "  Tool:        $Tool" -ForegroundColor Cyan
Write-Host "  Environment: $Environment" -ForegroundColor Cyan
Write-Host "  Policy ref:  $PolicyRef" -ForegroundColor Cyan
Write-Host "  Config ref:  $ConfigRef" -ForegroundColor Cyan
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host ""

# ── Step 1: Fetch scan-config from product repo ─────────────
Write-Host "=== Step 1/5: Fetching scan-config ===" -ForegroundColor White
$scanConfigPath = & "$scriptDir\Get-ScanConfig.ps1" -Tool $Tool -Org $Org -Ref $PolicyRef

$scanConfig   = & yq -o json "." $scanConfigPath | ConvertFrom-Json
$scanType     = $scanConfig.scan_type
$envConfig    = $scanConfig.environments.$Environment

if (-not $envConfig) {
    Write-Error "No config for environment '$Environment' in scan-config.yaml for $Tool"
    exit 1
}

$scoreThreshold = if ($envConfig.score_threshold) { $envConfig.score_threshold } else { 80 }
$queue          = if ($envConfig.queue) { $envConfig.queue } else { "mondoo-scanners" }

Write-Host "Scan type: $scanType | Threshold: $scoreThreshold | Queue: $queue" -ForegroundColor Gray
Write-Host ""

# ── Step 2: Pull MQL policies ───────────────────────────────
Write-Host "=== Step 2/5: Pulling MQL policies ===" -ForegroundColor White
$policyDir = & "$scriptDir\Pull-Policies.ps1" -Tool $Tool -Org $Org -Ref $PolicyRef
Write-Host ""

# ── Step 3: Pull thresholds ─────────────────────────────────
Write-Host "=== Step 3/5: Pulling thresholds ===" -ForegroundColor White
& "$scriptDir\Pull-Thresholds.ps1" -Tool $Tool -Environment $Environment -Org $Org -Ref $ConfigRef | Out-Null
Write-Host ""

# ── Step 4: Merge thresholds ────────────────────────────────
Write-Host "=== Step 4/5: Merging thresholds ===" -ForegroundColor White
$mergedConfig = & "$scriptDir\Merge-Thresholds.ps1" -Tool $Tool
Write-Host ""

# ── Step 5: Configure Mondoo and execute scans ──────────────
Write-Host "=== Step 5/5: Executing cnspec scans ===" -ForegroundColor White

# Configure Mondoo credentials
if ($env:MONDOO_CONFIG_BASE64) {
    $mondooDir = Join-Path $env:USERPROFILE ".config\mondoo"
    New-Item -ItemType Directory -Path $mondooDir -Force | Out-Null
    $mondooConfig = Join-Path $mondooDir "mondoo.yml"
    [System.IO.File]::WriteAllBytes($mondooConfig, [System.Convert]::FromBase64String($env:MONDOO_CONFIG_BASE64))
}

# Build policy file flags
$policyFiles = Get-ChildItem -Path $policyDir -Filter "*.mql.yaml"
$policyFlags = ($policyFiles | ForEach-Object { "-f `"$($_.FullName)`"" }) -join " "

# Resolve targets
$targets = @()
if ($TargetOverride) {
    $targets += $TargetOverride
} else {
    foreach ($t in $envConfig.targets) {
        switch ($scanType) {
            "ssh"    { $targets += "$($t.host):$($t.port)" }
            "winrm"  { $targets += "$($t.host):$($t.port)" }
            "docker" { $targets += $t.container }
            "k8s"    { $targets += "k8s" }
            "github" { $targets += "github" }
            "api"    { $targets += "local" }
        }
    }
}

if ($targets.Count -eq 0) {
    Write-Error "No targets found for $Tool/$Environment in scan-config.yaml"
    exit 1
}

Write-Host "Targets: $($targets -join ', ')" -ForegroundColor Gray
Write-Host "Policy files: $($policyFiles.Count)" -ForegroundColor Gray
Write-Host ""

# Track results
$overallExit = 0
$resultsDir = Join-Path $env:TEMP "mondoo-results\$Tool"
New-Item -ItemType Directory -Path $resultsDir -Force | Out-Null

foreach ($target in $targets) {
    Write-Host "--- Scanning: $target ---" -ForegroundColor Yellow
    $safeName   = $target -replace "[:/.]", "-"
    $resultFile = Join-Path $resultsDir "$safeName.json"

    $cnspecArgs = @()

    switch ($scanType) {
        "ssh" {
            $parts = $target -split ":"
            $cnspecArgs = @(
                "scan", "ssh", $parts[0],
                "--port", $parts[1]
            )
        }
        "winrm" {
            $parts = $target -split ":"
            $cnspecArgs = @(
                "scan", "winrm", "Administrator@$($parts[0])"
            )
        }
        "docker" {
            $cnspecArgs = @(
                "scan", "docker", "container", $target
            )
        }
        "k8s" {
            $ns  = $envConfig.namespace
            $ctx = $envConfig.context
            $cnspecArgs = @(
                "scan", "k8s",
                "--context", $ctx,
                "--namespace", $ns
            )
        }
        "github" {
            $ghOrg = $envConfig.org
            $cnspecArgs = @(
                "scan", "github", "org", $ghOrg
            )
        }
        "api" {
            $cnspecArgs = @(
                "scan", "local"
            )
        }
    }

    # Append common flags
    foreach ($pf in $policyFiles) {
        $cnspecArgs += "-f"
        $cnspecArgs += $pf.FullName
    }
    $cnspecArgs += "--props"
    $cnspecArgs += "merged_config=$mergedConfig"
    $cnspecArgs += "--score-threshold"
    $cnspecArgs += "$scoreThreshold"
    $cnspecArgs += "--output"
    $cnspecArgs += "json"
    $cnspecArgs += "--output-target"
    $cnspecArgs += $resultFile

    Write-Host "Running: cnspec $($cnspecArgs -join ' ')" -ForegroundColor DarkGray

    & cnspec @cnspecArgs
    if ($LASTEXITCODE -ne 0) {
        $overallExit = 1
    }

    Write-Host ""
}

# ── Report ───────────────────────────────────────────────────
Write-Host ("=" * 60) -ForegroundColor Cyan
Write-Host "  Scan Complete" -ForegroundColor Cyan
Write-Host "  Tool:        $Tool"
Write-Host "  Environment: $Environment"
Write-Host "  Targets:     $($targets.Count)"

if ($overallExit -eq 0) {
    Write-Host "  Status:      PASSED (threshold: $scoreThreshold)" -ForegroundColor Green
    try {
        & buildkite-agent annotate --style "success" `
            "✅ **$Tool** ($Environment) — passed all checks (threshold: $scoreThreshold)" `
            --context "scan-$Tool" 2>$null
    } catch {}
} else {
    Write-Host "  Status:      FAILED (threshold: $scoreThreshold)" -ForegroundColor Red
    try {
        & buildkite-agent annotate --style "error" `
            "❌ **$Tool** ($Environment) — below scan threshold $scoreThreshold" `
            --context "scan-$Tool" 2>$null
    } catch {}
}

Write-Host ("=" * 60) -ForegroundColor Cyan

# Upload artifacts
try {
    & buildkite-agent artifact upload "$resultsDir\*" 2>$null
} catch {}

exit $overallExit
