<#
  Upgrade MARS-Curiosity (git submodule backend\3thParty\MARS) to a release tag.

    powershell -File tools\update-mars.ps1 -Tag v.2.0.4

  1. fetches the tag (shallow) and checks it out in the submodule,
  2. updates MARS's own submodules (delphi-jose-jwt, needed for Linux64),
  3. updates backend\3thParty\DEPENDENCIES.md and prints the release notes
     (read the "Upgrade notes" before building!).

  Afterwards: clear the DCU folder, build Win32 + Linux64, run the tests, then
  commit the new submodule pointer on its own:  git add backend/3thParty/MARS ...
#>
param(
  [Parameter(Mandatory = $true)][string]$Tag,
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1: $PSScriptRoot is not available in param() defaults
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path }
$mars = Join-Path $RepoRoot 'backend\3thParty\MARS'
$deps = Join-Path $RepoRoot 'backend\3thParty\DEPENDENCIES.md'

function Git { git @args; if ($LASTEXITCODE -ne 0) { throw "git $($args -join ' ') failed" } }

if (-not (Test-Path (Join-Path $mars '.git'))) {
  Write-Host '==> submodule not initialised yet - initialising' -ForegroundColor Cyan
  Git -C $RepoRoot submodule update --init --recursive --depth 1
}

Write-Host "==> MARS $Tag" -ForegroundColor Cyan
Git -C $mars fetch --depth 1 origin tag $Tag
Git -C $mars -c advice.detachedHead=false checkout $Tag
Git -C $mars submodule update --init --recursive --depth 1
$commit = (git -C $mars rev-parse HEAD).Trim()
$jose = (git -C $mars rev-parse "HEAD:ThirdParty/delphi-jose-jwt").Trim()
Write-Host "    commit $commit"
Write-Host "    delphi-jose-jwt $jose"

$c = Get-Content $deps -Raw
$c = $c -replace '<!--mars-tag-->.*?<!--/mars-tag-->', "<!--mars-tag-->$Tag<!--/mars-tag-->"
$c = $c -replace '<!--mars-commit-->.*?<!--/mars-commit-->', "<!--mars-commit-->$commit<!--/mars-commit-->"
$c = $c -replace '<!--mars-date-->.*?<!--/mars-date-->', ("<!--mars-date-->" + (Get-Date -Format 'yyyy-MM-dd') + "<!--/mars-date-->")
$c = $c -replace '<!--jose-commit-->.*?<!--/jose-commit-->', "<!--jose-commit-->$jose<!--/jose-commit-->"
[IO.File]::WriteAllText($deps, $c)

try {
  $rel = Invoke-RestMethod -Headers @{ 'User-Agent' = 'update-mars' } "https://api.github.com/repos/andrea-magni/MARS/releases/tags/$Tag"
  Write-Host ''
  Write-Host "Release notes ($($rel.name)) - check the 'Upgrade notes':" -ForegroundColor Yellow
  Write-Host $rel.body
} catch {
  Write-Host "(release notes not available: $($_.Exception.Message))" -ForegroundColor DarkGray
}
Write-Host ''
Write-Host "Next: clear the DCU folder, build Win32 + Linux64, run the tests, then:" -ForegroundColor Cyan
Write-Host "  git add backend/3thParty/MARS backend/3thParty/DEPENDENCIES.md; git commit -m 'MARS -> $Tag'"
