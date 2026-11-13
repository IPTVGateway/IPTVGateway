<#
  build.ps1 - one-shot packaging for IPTV Gateway on Unraid (and any Docker host).

  Does, in order:
    1. cross-compile the Linux64 service binary (RAD Studio; uses the staged
       glibc sysroot in deploy\linux-sysroot, so NO RAD Studio Linux SDK import
       is required),
    2. stage it next to the Dockerfile,
    3. build the Docker image,
    4. export everything into .Output\Docker as a ready-to-ship bundle:
       iptvplay.tar.gz + docker-compose.yml + iptv-gateway.xml + config.json + README,
    5. publish the bundle to the NAS share (-PublishTo) Unraid reads, FIRST archiving
       the release already there into <PublishTo>\backups (the tar always has the same
       name, so this is what stops an update from destroying the previous image).

  Works with EITHER Docker Desktop (docker on PATH) OR Docker installed inside
  WSL2 (no Docker Desktop) - it auto-detects. For the WSL path the build context
  is copied under C:\Temp (WSL can read /mnt/c but not your project drive).

  Prerequisites:
    - RAD Studio 13 (for the Delphi Linux64 compiler + its bundled ld-linux).
    - Docker available (Docker Desktop, or 'docker' inside WSL).
    NOTE: a PAServer / Linux SDK import is NOT needed - the system libs are
    resolved from deploy\linux-sysroot.

  Usage (from anywhere):
    powershell -ExecutionPolicy Bypass -File deploy\docker\build.ps1
    # options:
    #   -Config Debug            (default Release)
    #   -Bds "<RAD Studio dir>"
    #   -Tag iptvplay:latest
    #   -SaveTo "<path>\iptvplay.tar.gz"   (default .Output\Docker\iptvplay.tar.gz)
    #   -WslDistro Ubuntu
    #   -SkipBuild               (reuse an already-staged Linux64 binary)
    #   -SkipDocker              (only compile + stage the binary)
    #   -NoSave                  (build the image but don't export the bundle)
    #   -PublishTo "<path>"      (copy bundle to the NAS; '' = don't publish)
    #   -KeepBackups 10          (dated archives to keep in <PublishTo>\backups)
#>
[CmdletBinding()]
param(
  [string]$Config = 'Release',
  [string]$Bds = 'D:\Program Files (x86)\Embarcadero\Studio\37.0',
  [string]$Tag = 'iptvplay:latest',
  [string]$SaveTo = '',
  [string]$WslDistro = 'Ubuntu',
  [string]$Repo = '',        # registry repo, e.g. youruser/iptv-gateway (for -Push)
  [string]$Version = '',     # extra version tag to push alongside :latest, e.g. 1.0.0
  [switch]$Push,             # tag + push to $Repo (run 'docker login' once first)
  [switch]$SkipBuild,
  [switch]$SkipDocker,
  [switch]$NoSave,
  # copy bundle here ('' = don't). Default: deploy\docker\publish-target.local.txt
  # (one line, gitignored) or $env:IPTV_PUBLISH_TO, e.g. \\your-nas\Docker\IPTV Gateway
  [string]$PublishTo = $null,
  [int]$KeepBackups = 10     # how many dated archives to keep in <PublishTo>\backups
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path          # deploy\docker
if (-not $PSBoundParameters.ContainsKey('PublishTo')) {
  $localTarget = Join-Path $here 'publish-target.local.txt'
  if (Test-Path $localTarget) { $PublishTo = (Get-Content $localTarget -TotalCount 1).Trim() }
  elseif ($env:IPTV_PUBLISH_TO) { $PublishTo = $env:IPTV_PUBLISH_TO }
  else { $PublishTo = '' }
}
# registry push by default when deploy\docker\push-registry.local.txt (gitignored)
# names a repo, e.g. ghcr.io/youruser/iptv-gateway ('docker login' done once).
# Unraid then sees "update ready" and updates in one click.
if (-not $PSBoundParameters.ContainsKey('Repo')) {
  $localRepo = Join-Path $here 'push-registry.local.txt'
  if (Test-Path $localRepo) {
    $Repo = (Get-Content $localRepo -TotalCount 1).Trim()
    if ($Repo -and -not $PSBoundParameters.ContainsKey('Push')) { $Push = [switch]$true }
  }
}
$repo = (Resolve-Path (Join-Path $here '..\..')).Path
$dproj = Join-Path $repo 'backend\src\host_service\IPTVPlayService.dproj'
$rsvars = Join-Path $Bds 'bin\rsvars.bat'
$elf = Join-Path $repo (".Output\Linux64\$Config\IPTVPlayService")
$staged = Join-Path $here 'IPTVPlayService'
$outDir = Join-Path $repo '.Output\Docker'
if (-not $SaveTo) { $SaveTo = Join-Path $outDir 'iptvplay.tar.gz' }

# version: read APP_VERSION from the Pascal source (single source of truth) unless
# one was passed in. Used to add an 'iptvplay:<version>' image tag (so the running
# version is visible in Unraid's image list + the app header) and to name backups.
if (-not $Version) {
  $cfgPas = Join-Path $repo 'backend\src\core\app\IPTV.App.Config.pas'
  if (Test-Path $cfgPas) {
    $vm = Select-String -Path $cfgPas -Pattern "APP_VERSION\s*=\s*'([^']+)'" | Select-Object -First 1
    if ($vm) { $Version = $vm.Matches[0].Groups[1].Value }
  }
}
$verTag = if ($Version) { "iptvplay:$Version" } else { '' }
if ($Version) { Write-Host "    version: $Version" -ForegroundColor DarkGray }

# -- 1+2. compile Linux64 + stage the binary --------------------------------
if (-not $SkipBuild) {
  if (-not (Test-Path $rsvars)) { throw "rsvars.bat not found at $rsvars - pass -Bds <RAD Studio dir>" }
  if (-not (Test-Path $dproj))  { throw "project not found: $dproj" }
  Write-Host "==> Building Linux64 ($Config) ..." -ForegroundColor Cyan
  cmd /c "`"$rsvars`" && msbuild `"$dproj`" /t:Build /p:Config=$Config /p:Platform=Linux64 /p:ProductVersion=37.0 /v:m /nologo"
  if ($LASTEXITCODE -ne 0) { throw "Linux64 build failed (see linker output above)." }
  if (-not (Test-Path $elf)) { throw "expected binary not found at $elf" }
  Copy-Item $elf $staged -Force
}
if (-not (Test-Path $staged)) { throw "no staged binary at $staged - run without -SkipBuild first" }
Write-Host "    staged: $staged ($([math]::Round((Get-Item $staged).Length/1MB,1)) MB)"

# stage the built React admin UI next to the Dockerfile (deploy\docker\webui) so
# the image bundles it (served at / by the service). Run 'npm run build' in
# frontend\ first; we just copy whatever dist is there.
$dist = Join-Path $repo 'frontend\dist'
$webui = Join-Path $here 'webui'
if (Test-Path $dist) {
  if (Test-Path $webui) { Remove-Item $webui -Recurse -Force }
  Copy-Item $dist $webui -Recurse -Force
  Write-Host "    admin UI staged from $dist"
} elseif (-not (Test-Path $webui)) {
  Write-Host "    WARNING: no frontend\dist and no staged webui - image will be API-only." -ForegroundColor Yellow
  New-Item -ItemType Directory -Force $webui | Out-Null   # empty dir so COPY webui doesn't fail
}

# strip debug symbols to shrink the image (best effort - needs 'strip' in WSL).
# (The Delphi linker already passes -s, so this is usually a no-op.)
try {
  $hasStrip = wsl -d $WslDistro -- bash -lc "command -v strip" 2>$null
  if ($hasStrip) {
    New-Item -ItemType Directory -Force 'C:\Temp' | Out-Null
    Copy-Item $staged 'C:\Temp\IPTVPlayService.strip' -Force
    wsl -d $WslDistro -- bash -lc "strip --strip-unneeded /mnt/c/Temp/IPTVPlayService.strip"
    if ($LASTEXITCODE -eq 0) {
      Copy-Item 'C:\Temp\IPTVPlayService.strip' $staged -Force
      Write-Host "    stripped: $([math]::Round((Get-Item $staged).Length/1MB,1)) MB"
    }
    Remove-Item 'C:\Temp\IPTVPlayService.strip' -Force -ErrorAction SilentlyContinue
  }
} catch { Write-Host "    (strip skipped: $($_.Exception.Message))" -ForegroundColor DarkGray }

if ($SkipDocker) { Write-Host "Done (skipped docker)." -ForegroundColor Green; return }

# helper that copies the deploy bundle (compose/template/config/README) next to the
# tar. When -Repo is set, the bundled Unraid template is pointed at that registry
# image (so forum users pull it) instead of the local 'iptvplay:latest' tag.
function Copy-Bundle($destDir) {
  New-Item -ItemType Directory -Force $destDir | Out-Null
  foreach ($f in 'docker-compose.yml','iptv-gateway.xml','config.json','README.txt') {
    $src = Join-Path $here $f
    if (Test-Path $src) { Copy-Item $src $destDir -Force }
  }
  if ($Repo) {
    $xml = Join-Path $destDir 'iptv-gateway.xml'
    if (Test-Path $xml) {
      $c = Get-Content $xml -Raw
      $c = $c -replace '<Repository>[^<]*</Repository>', "<Repository>$Repo`:latest</Repository>"
      $reg = if ($Repo -like 'ghcr.io/*') { 'https://ghcr.io' } else { "https://hub.docker.com/r/$Repo" }
      $c = $c -replace '<Registry\s*/>', "<Registry>$reg</Registry>"
      $c = $c -replace '<Registry>[^<]*</Registry>', "<Registry>$reg</Registry>"
      Set-Content $xml $c -Encoding UTF8
    }
  }
}

# Copy one file to a directory RELIABLY. The Unraid SMB share silently corrupts
# large files copied with Copy-Item (the write "succeeds" and the size matches, but
# the bytes are mangled -> `docker load` later fails with "invalid tar header").
# robocopy (restartable /Z) transfers cleanly; we still verify the MD5 and retry,
# so a bad copy can never be published. Returns $true on a verified copy.
function Copy-Verified($srcFile, $destDir, $destName) {
  if (-not $destName) { $destName = Split-Path $srcFile -Leaf }
  $srcName = Split-Path $srcFile -Leaf
  $want = (Get-FileHash $srcFile -Algorithm MD5).Hash
  $final = Join-Path $destDir $destName
  for ($i = 1; $i -le 4; $i++) {
    if (Test-Path $final) { Remove-Item $final -Force -ErrorAction SilentlyContinue }
    # robocopy copies under the source name; rename afterwards if a different name is wanted
    robocopy (Split-Path $srcFile -Parent) $destDir $srcName /Z /R:5 /W:3 /NP /NJH /NJS /NFL /NDL | Out-Null
    $landed = Join-Path $destDir $srcName
    if ((Test-Path $landed) -and ($srcName -ne $destName)) { Move-Item $landed $final -Force }
    if ((Test-Path $final) -and ((Get-FileHash $final -Algorithm MD5).Hash -eq $want)) { return $true }
    Write-Host "    copy of $destName not verified (attempt $i), retrying" -ForegroundColor Yellow
  }
  return $false
}

# Publish the freshly-exported bundle to $destDir (e.g. the NAS share Unraid reads),
# but FIRST archive the release currently there into <destDir>\backups (the bundle
# always uses the same file name, so a plain copy would otherwise destroy the
# previous image with no way back). Also keeps a dated copy of the NEW tar and
# prunes to the newest $KeepBackups archives.
function Publish-Bundle($srcDir, $destDir) {
  if (-not $destDir) { return }
  if (-not (Test-Path $destDir)) {
    try { New-Item -ItemType Directory -Force $destDir -ErrorAction Stop | Out-Null }
    catch { Write-Host "    publish skipped: cannot reach $destDir" -ForegroundColor Yellow; return }
  }
  $bdir = Join-Path $destDir 'backups'
  New-Item -ItemType Directory -Force $bdir | Out-Null
  $destTar = Join-Path $destDir 'iptvplay.tar.gz'
  # preserve the release already on the NAS (stamped with ITS build time) before overwriting
  if (Test-Path $destTar) {
    $stamp = (Get-Item $destTar).LastWriteTime.ToString('yyyy-MM-dd_HHmm')
    $prev = Join-Path $bdir "iptvplay-$stamp.tar.gz"
    if (-not (Test-Path $prev)) { Copy-Item $destTar $prev -Force }
  }
  # publish the NEW image tar with verification (large + corruption-prone over SMB)
  if (-not (Copy-Verified (Join-Path $srcDir 'iptvplay.tar.gz') $destDir)) {
    throw "publish aborted: could not copy a verified iptvplay.tar.gz to $destDir (flaky share?)"
  }
  # the small deploy files (tiny; Copy-Item is fine for these)
  foreach ($f in 'docker-compose.yml','iptv-gateway.xml','config.json','README.txt') {
    $s = Join-Path $srcDir $f
    if (Test-Path $s) { Copy-Item $s $destDir -Force }
  }
  # archive a dated (and versioned) copy of the new tar too — also verified
  $verPart = if ($Version) { "$Version-" } else { '' }
  $bakName = "iptvplay-{0}{1}.tar.gz" -f $verPart, (Get-Date).ToString('yyyy-MM-dd_HHmm')
  [void](Copy-Verified (Join-Path $srcDir 'iptvplay.tar.gz') $bdir $bakName)
  if ($KeepBackups -gt 0) {
    Get-ChildItem $bdir -Filter 'iptvplay-*.tar.gz' | Sort-Object LastWriteTime -Descending |
      Select-Object -Skip $KeepBackups | Remove-Item -Force -ErrorAction SilentlyContinue
  }
  Write-Host "==> published to $destDir (verified; previous release archived in backups\)" -ForegroundColor Cyan
}

# tag + push to the registry (docker runs natively or in WSL). Assumes 'docker login' done.
function Push-Image {
  $tags = @("$Repo`:latest")
  if ($Version) { $tags += "$Repo`:$Version" }
  foreach ($t in $tags) {
    Write-Host "==> push $t ..." -ForegroundColor Cyan
    if (Get-Command docker -ErrorAction SilentlyContinue) {
      docker tag $Tag $t; docker push $t
    } else {
      wsl -d $WslDistro -u root -- bash -lc "docker info >/dev/null 2>&1 || { nohup dockerd >/var/log/dockerd.log 2>&1 & sleep 3; }; docker tag $Tag $t && docker push $t"
    }
    if ($LASTEXITCODE -ne 0) { throw "docker push $t failed (did you 'docker login'?)" }
  }
}

# -- 3+4. build the image + export the bundle -------------------------------
$native = Get-Command docker -ErrorAction SilentlyContinue
if ($native) {
  Write-Host "==> docker build -t $Tag (Docker Desktop) ..." -ForegroundColor Cyan
  docker build -t $Tag $here
  if ($LASTEXITCODE -ne 0) { throw "docker build failed" }
  if ($verTag) { docker tag $Tag $verTag }   # extra version tag, saved alongside :latest
  if (-not $NoSave) {
    New-Item -ItemType Directory -Force (Split-Path $SaveTo) | Out-Null
    Write-Host "==> exporting $SaveTo ..." -ForegroundColor Cyan
    $tmpTar = [System.IO.Path]::GetTempFileName()
    $saveRefs = @($Tag); if ($verTag) { $saveRefs += $verTag }
    docker save @saveRefs -o $tmpTar
    if ($LASTEXITCODE -ne 0) { throw "docker save failed" }
    $in = [System.IO.File]::OpenRead($tmpTar)
    $outFs = [System.IO.File]::Create($SaveTo)
    $gz = New-Object System.IO.Compression.GZipStream($outFs, [System.IO.Compression.CompressionMode]::Compress)
    try { $in.CopyTo($gz) } finally { $gz.Dispose(); $outFs.Dispose(); $in.Dispose(); Remove-Item $tmpTar -Force }
    Copy-Bundle (Split-Path $SaveTo)
  }
}
else {
  # No Docker Desktop - use docker inside WSL. WSL can't see this drive, so copy
  # the (small) build context under C:\Temp which maps to /mnt/c.
  Write-Host "==> docker not on PATH; using docker inside WSL ($WslDistro) ..." -ForegroundColor Cyan
  $ctxWin = 'C:\Temp\iptv-docker-ctx'
  $ctxWsl = '/mnt/c/Temp/iptv-docker-ctx'
  $tarWsl = '/mnt/c/Temp/iptvplay.tar.gz'
  $tarWin = 'C:\Temp\iptvplay.tar.gz'
  if (Test-Path $ctxWin) { Remove-Item $ctxWin -Recurse -Force }
  New-Item -ItemType Directory -Force $ctxWin | Out-Null
  foreach ($f in 'Dockerfile', '.dockerignore', 'config.json', 'IPTVPlayService') {
    Copy-Item (Join-Path $here $f) (Join-Path $ctxWin $f) -Force
  }
  # the admin UI directory (Dockerfile does COPY webui)
  if (Test-Path (Join-Path $here 'webui')) {
    Copy-Item (Join-Path $here 'webui') (Join-Path $ctxWin 'webui') -Recurse -Force
  }
  # robust daemon start: many WSL distros have no init script for docker, so fall
  # back to launching dockerd directly; then wait for the socket.
  $tagCmd = if ($verTag) { "docker tag $Tag $verTag" } else { 'true' }
  $saveRefs = if ($verTag) { "$Tag $verTag" } else { "$Tag" }
  $saveCmd = if ($NoSave) { '' } else { "docker save $saveRefs | gzip > $tarWsl" }
  $runner = @"
#!/bin/bash
set -e
docker info >/dev/null 2>&1 || service docker start >/dev/null 2>&1 || true
for i in `$(seq 1 40); do
  docker info >/dev/null 2>&1 && break
  if [ "`$i" = "5" ] && ! pgrep -x dockerd >/dev/null 2>&1; then nohup dockerd >/var/log/dockerd.log 2>&1 & fi
  sleep 1
done
docker info >/dev/null 2>&1 || { echo 'docker daemon failed to start'; tail -20 /var/log/dockerd.log 2>/dev/null; exit 1; }
cd $ctxWsl
docker build -t $Tag .
$tagCmd
$saveCmd
"@
  # write the runner as LF and execute it in WSL as root
  $runnerPath = Join-Path $ctxWin 'run.sh'
  [System.IO.File]::WriteAllText($runnerPath, ($runner -replace "`r`n","`n"))
  wsl -d $WslDistro -u root -- bash "$ctxWsl/run.sh"
  if ($LASTEXITCODE -ne 0) { throw "WSL docker build/save failed" }
  if (-not $NoSave) {
    New-Item -ItemType Directory -Force (Split-Path $SaveTo) | Out-Null
    Move-Item $tarWin $SaveTo -Force
    Copy-Bundle (Split-Path $SaveTo)
  }
  Remove-Item $ctxWin -Recurse -Force
}

# copy the bundle to the NAS (with backup rotation) unless we didn't export one
if (-not $NoSave -and $PublishTo) { Publish-Bundle (Split-Path $SaveTo) $PublishTo }

if ($Push) {
  if (-not $Repo) { throw '-Push requires -Repo <user/name> (e.g. youruser/iptv-gateway)' }
  Push-Image
}

if (-not $NoSave) {
  Write-Host "Done. Bundle in $(Split-Path $SaveTo):" -ForegroundColor Green
  Get-ChildItem (Split-Path $SaveTo) | ForEach-Object { Write-Host ("  {0}" -f $_.Name) }
  Write-Host "Copy iptvplay.tar.gz to the host and run:  docker load -i iptvplay.tar.gz"
}
else {
  Write-Host "Done. Image '$Tag' built." -ForegroundColor Green
}
