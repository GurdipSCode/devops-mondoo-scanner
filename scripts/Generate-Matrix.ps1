#Requires -Version 5.1
<#
.SYNOPSIS
    Reads scan-config.yaml from all product repos and generates
    a dynamic Buildkite pipeline with parallel scan steps.

.DESCRIPTION
    For the scheduled fleet scan. Iterates the known tool list,
    fetches each tool's .buildkite/scan-config.yaml, and emits
    a Buildkite YAML pipeline with one step per tool/environment.
#>

[CmdletBinding()]
param(
    [string]$Environment = $env:SCAN_ENV,
    [string]$Org = "GurdipSCode"
)

if (-not $Environment) { $Environment = "production" }

$ErrorActionPreference = "Stop"
$scriptDir = Join-Path $PSScriptRoot "..\scripts"

# All 28 tools
$tools = @(
    "archestra", "argocd", "axiom", "buildkite", "checkly", "cloudflare",
    "cloudsmith", "elastic", "github", "gns3", "grafana", "idrac",
    "kestra", "lynx", "mondoo", "netbox", "netlify", "ngrok",
    "octopusdeploy", "onmanage", "portainer", "portio", "splunk",
    "tailscale", "teamcity", "vault", "vcf", "veeam"
)

$outputPath = Join-Path $env:TEMP "mondoo-dynamic-pipeline.yaml"

Write-Host "--- :gear: Generating scan matrix for $Environment" -ForegroundColor Cyan

$yaml = "steps:`n"
$toolCount = 0

foreach ($tool in $tools) {
    Write-Host "  Checking $tool..." -NoNewline

    # Try to fetch scan-config from the product repo
    $token = $env:POLICY_REPO_TOKEN
    if (-not $token) {
        try { $token = & buildkite-agent secret get POLICY_REPO_TOKEN 2>$null } catch {}
    }

    $repo = "devops-configs-policies-$tool"
    $uri  = "https://api.github.com/repos/$Org/$repo/contents/.buildkite/scan-config.yaml?ref=main"
    $headers = @{
        Authorization = "token $token"
        Accept        = "application/vnd.github.v3.raw"
        "User-Agent"  = "mondoo-runner"
    }

    try {
        $configContent = Invoke-RestMethod -Uri $uri -Headers $headers
        $configPath = Join-Path $env:TEMP "scan-config-$tool.yaml"
        $configContent | Out-File -FilePath $configPath -Encoding utf8

        # Check if this tool has the requested environment
        $hasEnv = & yq ".environments.$Environment" $configPath 2>$null
        if ($hasEnv -eq "null" -or -not $hasEnv) {
            Write-Host " skipped (no $Environment config)" -ForegroundColor DarkGray
            continue
        }

        $scanType = & yq ".scan_type" $configPath
        $threshold = & yq ".environments.$Environment.score_threshold // 80" $configPath
        $queue = & yq ".environments.$Environment.queue // `"mondoo-scanners`"" $configPath

        # Choose emoji
        $emoji = switch ($scanType) {
            "ssh"    { ":terminal:" }
            "docker" { ":docker:" }
            "k8s"    { ":kubernetes:" }
            "github" { ":github:" }
            "winrm"  { ":windows:" }
            "api"    { ":globe_with_meridians:" }
            default  { ":shield:" }
        }

        $yaml += @"
  - label: "$emoji $tool ($Environment)"
    key: "scan-$tool"
    command: "powershell -ExecutionPolicy Bypass -File scripts\Invoke-Scan.ps1 -Tool $tool -Environment $Environment"
    env:
      SCAN_TOOL: "$tool"
      SCAN_ENV: "$Environment"
    agents:
      queue: "$queue"
    timeout_in_minutes: 30
    soft_fail:
      - exit_status: 1
    retry:
      automatic:
        - exit_status: -1
          limit: 2
    artifact_paths:
      - "C:\\Users\\**\\AppData\\Local\\Temp\\mondoo-results\\$tool\\**\\*"

"@
        $toolCount++
        Write-Host " added ($scanType, threshold=$threshold)" -ForegroundColor Green

    } catch {
        Write-Host " skipped (no scan-config.yaml found)" -ForegroundColor DarkGray
        continue
    }
}

# Add summary step
$yaml += @"
  - wait: ~
    continue_on_failure: true

  - label: ":bar_chart: Scan Summary"
    key: "summary"
    command: |
      powershell -ExecutionPolicy Bypass -Command "
        Write-Host '--- :shield: Mondoo Fleet Scan Results'
        `$pass = 0; `$fail = 0
        `$resultDirs = Get-ChildItem -Path `$env:TEMP\mondoo-results -Directory -ErrorAction SilentlyContinue
        foreach (`$dir in `$resultDirs) {
          `$hasResults = Get-ChildItem -Path `$dir.FullName -Filter '*.json' -ErrorAction SilentlyContinue
          if (`$hasResults) {
            Write-Host ('PASSED: ' + `$dir.Name) -ForegroundColor Green
            `$pass++
          } else {
            Write-Host ('FAILED: ' + `$dir.Name) -ForegroundColor Red
            `$fail++
          }
        }
        Write-Host ''
        Write-Host ('Passed: ' + `$pass + ' | Failed: ' + `$fail + ' | Total: ' + (`$pass + `$fail))
      "
    agents:
      queue: "mondoo-scanners"
"@

$yaml | Out-File -FilePath $outputPath -Encoding utf8

Write-Host ""
Write-Host "Generated $toolCount scan steps -> $outputPath" -ForegroundColor Green

# Upload for the next step
& buildkite-agent pipeline upload $outputPath
