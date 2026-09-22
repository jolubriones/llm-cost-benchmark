# Publish llm-cost-benchmark to GitHub Pages.
# Requires: gh auth login completed once (browser device flow).
# Usage: .\publish.ps1 [-RepoName llm-cost-benchmark]
param(
  [string]$RepoName = "llm-cost-benchmark",
  [string]$Description = "The 112x Finding - what frontier LLMs actually cost to do the same job (real billed API spend, MiMo v2.6-flash $0.0025 vs Opus 5 $0.28)."
)
$gh = "$env:ProgramFiles\GitHub CLI\gh.exe"
if (-not (Test-Path $gh)) { $gh = 'gh' }
$ErrorActionPreference = 'Continue'

# who am I?
$user = & $gh api user --jq .login
if (-not $user) { Write-Host 'Not authenticated. Run: & "C:\Program Files\GitHub CLI\gh.exe" auth login' -ForegroundColor Red; exit 1 }
Write-Host "Authenticated as $user" -ForegroundColor Green
$pagesUrl = "https://$user.github.io/$RepoName/"

# 1. Stamp the real domain into SEO files BEFORE committing
foreach ($f in 'sitemap.xml', 'index.html') {
  if (Test-Path $f) {
    $c = Get-Content $f -Raw -Encoding UTF8
    $c = $c -replace 'https://SITE_DOMAIN', $pagesUrl.TrimEnd('/')
    $c = $c -replace [regex]::Escape('./index.html'), $pagesUrl
    $c = $c -replace [regex]::Escape('./README.md'), "$pagesUrl/README.md"
    Set-Content -Path $f -Value $c -Encoding UTF8 -NoNewline
    Write-Host "Stamped $f -> $pagesUrl"
  }
}

# 2. Commit everything
if (-not (Test-Path .git)) { git init -b main *> $null }
git add -A *> $null
$pending = git status --porcelain
if ($pending) { git commit -m "LLM cost benchmark: viz + presets + runner + docs" *> $null }

# 3. Create repo if missing, then push
$exists = & $gh repo view "$user/$RepoName" --json name --jq .name 2>$null
if (-not $exists) {
  & $gh repo create $RepoName --public --description $Description --source . --push
} else {
  if (-not (git remote)) { git remote add origin "https://github.com/$user/$RepoName.git" }
  git push -u origin main 2>&1 | Out-String | Write-Host
}

# 4. Enable Pages via API (main / root)
& $gh api -X POST "repos/$user/$RepoName/pages" -f "source[branch]=main" -f "source[path]=/" *> $null
if ($LASTEXITCODE -ne 0) { & $gh api -X PUT "repos/$user/$RepoName/pages" -f "source[branch]=main" -f "source[path]=/" *> $null }

Write-Host ''
Write-Host "Repo:      https://github.com/$user/$RepoName" -ForegroundColor Cyan
Write-Host "Live at:   $pagesUrl (Pages build takes ~1-2 min)" -ForegroundColor Cyan