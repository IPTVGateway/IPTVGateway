<#
  Upgrade the vendored MARS-Curiosity framework (backend\3thParty\MARS).

    powershell -File tools\update-mars.ps1 -Tag v.2.0.4

  1. downloads the release tarball of the tag,
  2. fetches the delphi-jose-jwt commit that MARS pins as a git submodule
     (a release tarball contains the submodule folder EMPTY),
  3. replaces backend\3thParty\MARS with only what the build uses,
  4. updates backend\3thParty\DEPENDENCIES.md and prints the release notes
     (read the "Upgrade notes" before building!).

  Afterwards: build Win32 + Linux64, run the tests, commit the upgrade on its own.
#>
param(
  [Parameter(Mandatory = $true)][string]$Tag,
  [string]$RepoRoot = ''
)
$ErrorActionPreference = 'Stop'
# Windows PowerShell 5.1: $PSScriptRoot is not available in param() defaults
if (-not $RepoRoot) { $RepoRoot = (Resolve-Path (Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) '..')).Path }
$api = 'https://api.github.com/repos/andrea-magni/MARS'
$hdr = @{ 'User-Agent' = 'update-mars'; 'Accept' = 'application/vnd.github+json' }

$dest = Join-Path $RepoRoot 'backend\3thParty\MARS'
$deps = Join-Path $RepoRoot 'backend\3thParty\DEPENDENCIES.md'
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("mars-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $tmp | Out-Null
try {
  Write-Host "==> MARS $Tag" -ForegroundColor Cyan
  $rel = Invoke-RestMethod -Headers $hdr "$api/releases/tags/$Tag"
  $commit = (Invoke-RestMethod -Headers $hdr "$api/commits/$Tag").sha
  $jose = (Invoke-RestMethod -Headers $hdr "$api/contents/ThirdParty/delphi-jose-jwt?ref=$Tag").sha
  Write-Host "    commit $commit"
  Write-Host "    delphi-jose-jwt $jose"

  $marsTar = Join-Path $tmp 'mars.tar.gz'
  $joseTar = Join-Path $tmp 'jose.tar.gz'
  Invoke-WebRequest -UseBasicParsing -Headers $hdr "https://github.com/andrea-magni/MARS/archive/refs/tags/$Tag.tar.gz" -OutFile $marsTar
  Invoke-WebRequest -UseBasicParsing -Headers $hdr "https://github.com/paolo-rossi/delphi-jose-jwt/archive/$jose.tar.gz" -OutFile $joseTar
  $mx = Join-Path $tmp 'm'; $jx = Join-Path $tmp 'j'
  New-Item -ItemType Directory -Force $mx, $jx | Out-Null
  tar -xzf $marsTar -C $mx; if ($LASTEXITCODE -ne 0) { throw 'extract MARS failed' }
  tar -xzf $joseTar -C $jx; if ($LASTEXITCODE -ne 0) { throw 'extract jose failed' }
  $ms = (Get-ChildItem $mx -Directory | Select-Object -First 1).FullName
  $js = (Get-ChildItem $jx -Directory | Select-Object -First 1).FullName
  if (-not (Test-Path (Join-Path $ms 'Source\MARS.Core.Engine.pas'))) { throw "unexpected MARS layout in $ms" }
  if (-not (Test-Path (Join-Path $js 'Source'))) { throw "unexpected delphi-jose-jwt layout in $js" }

  # replace the vendored folder with ONLY what the build uses
  if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
  New-Item -ItemType Directory -Force (Join-Path $dest 'ThirdParty\delphi-jose-jwt') | Out-Null
  Copy-Item (Join-Path $ms 'Source') $dest -Recurse
  foreach ($f in 'LICENSE', 'README.md', 'SECURITY.md', 'version.txt') {
    $src = Join-Path $ms $f
    if (Test-Path $src) { Copy-Item $src $dest }
  }
  Copy-Item (Join-Path $ms 'ThirdParty\mORMot') (Join-Path $dest 'ThirdParty') -Recurse
  $jd = Join-Path $dest 'ThirdParty\delphi-jose-jwt'
  Copy-Item (Join-Path $js 'Source') $jd -Recurse
  foreach ($f in 'LICENSE', 'README.md') {
    $src = Join-Path $js $f
    if (Test-Path $src) { Copy-Item $src $jd }
  }

  # manifest
  $c = Get-Content $deps -Raw
  $c = $c -replace '<!--mars-tag-->.*?<!--/mars-tag-->', "<!--mars-tag-->$Tag<!--/mars-tag-->"
  $c = $c -replace '<!--mars-commit-->.*?<!--/mars-commit-->', "<!--mars-commit-->$commit<!--/mars-commit-->"
  $c = $c -replace '<!--mars-date-->.*?<!--/mars-date-->', ("<!--mars-date-->" + (Get-Date -Format 'yyyy-MM-dd') + "<!--/mars-date-->")
  $c = $c -replace '<!--jose-commit-->.*?<!--/jose-commit-->', "<!--jose-commit-->$jose<!--/jose-commit-->"
  [IO.File]::WriteAllText($deps, $c)

  Write-Host "==> vendored into $dest" -ForegroundColor Green
  Write-Host ""
  Write-Host "Release notes ($($rel.name)) - check the 'Upgrade notes':" -ForegroundColor Yellow
  Write-Host $rel.body
  Write-Host ""
  Write-Host "Next: build Win32 + Linux64, run the tests, commit 'MARS -> $Tag' on its own." -ForegroundColor Cyan
}
finally {
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
