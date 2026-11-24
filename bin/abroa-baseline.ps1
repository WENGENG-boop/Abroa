# Explicit local test-environment operations; never targets development/production.
param(
  [ValidateSet("Prepare", "Unit", "System", "Lint", "All")]
  [string]$Phase = "All"
)

$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location -LiteralPath $root
try {
  foreach ($name in @(".env", ".env.local", ".env.test", ".env.test.local")) {
    if (Test-Path -LiteralPath $name) {
      throw "Refusing to mount a checkout containing $name. Use a clean test checkout without real credentials."
    }
  }

  $compose = @("compose", "-p", "abroa-p0-test", "-f", "compose.abroa-test.yml")
  $failures = New-Object System.Collections.Generic.List[string]

  function Invoke-Check([string]$Name, [string[]]$Arguments, [switch]$Required) {
    Write-Host "=== $Name ==="
    & docker @compose @Arguments
    $result = $LASTEXITCODE
    Write-Host "=== $Name exit=$result ==="
    if ($result -ne 0) {
      $failures.Add($Name)
      if ($Required) { throw "$Name failed with exit code $result" }
    }
  }

  Invoke-Check "Compose validation" @("config", "--quiet") -Required

  if ($Phase -in @("Prepare", "All")) {
    Invoke-Check "Build test image" @("build", "app") -Required
    Invoke-Check "Start isolated database and Redis" @("up", "-d", "--wait", "db", "redis") -Required
    Invoke-Check "Install locked gems" @("run", "--rm", "--no-deps", "app", "bundle", "install") -Required
    Invoke-Check "Prepare scratch database" @("run", "--rm", "--no-deps", "app", "bash", "-lc", "bundle exec ruby bin/rails db:create && bundle exec ruby bin/rails db:schema:load && bundle exec ruby bin/rails db:seed") -Required
  }

  if ($Phase -in @("Unit", "All")) {
    Invoke-Check "Full Minitest" @("run", "--rm", "app", "bundle", "exec", "ruby", "bin/rails", "test")
  }

  if ($Phase -in @("Lint", "All")) {
    Invoke-Check "RuboCop" @("run", "--rm", "--no-deps", "app", "bundle", "exec", "rubocop")
    Invoke-Check "ERB lint" @("run", "--rm", "--no-deps", "app", "bundle", "exec", "erb_lint", "./app/**/*.erb")
    Invoke-Check "Biome" @("run", "--rm", "--no-deps", "app", "bash", "-lc", "npm ci && npm run lint")
    Invoke-Check "Brakeman" @("run", "--rm", "--no-deps", "app", "bundle", "exec", "brakeman", "--no-pager")
  }

  if ($Phase -in @("System", "All")) {
    Invoke-Check "Start Selenium" @("--profile", "system", "up", "-d", "--wait", "selenium")
    if (-not $failures.Contains("Start Selenium")) {
      Invoke-Check "System tests" @("run", "--rm", "-e", "SELENIUM_REMOTE_URL=http://selenium:4444", "-e", "DISABLE_PARALLELIZATION=true", "app", "bundle", "exec", "ruby", "bin/rails", "test:system")
    }
  }

  if ($failures.Count -gt 0) { throw ("Failed checks: " + ($failures -join ", ")) }
} finally {
  Pop-Location
}
