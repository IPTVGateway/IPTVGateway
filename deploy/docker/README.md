# IPTVPlay in Docker (Unraid)

The service is a single cross-platform console daemon. Docker can't compile
Delphi, so you build the **Linux64** binary in RAD Studio first, then package it
here on a minimal Debian image.

## 0. One-time toolchain setup (Linux64 cross-build)

Delphi cross-compiles to Linux via a Linux host running **PAServer**. WSL2 works:

```powershell
wsl --install            # Ubuntu; reboot if prompted
```
Then inside Ubuntu (WSL):
```bash
sudo apt update && sudo apt install -y build-essential gdb libcurl4 openssl
# copy + unpack Embarcadero's PAServer for Linux, then run it:
#   (LinuxPAServer37.0.tar.gz ships in "<RAD Studio>\PAServer\")
tar xf LinuxPAServer37.0.tar.gz && cd PAServer-37.0 && ./paserver
```
In RAD Studio 13: **Tools ▸ Options ▸ Deployment ▸ Connection Profile Manager**
→ add a profile to the WSL host (localhost), then **SDK Manager** → import the
Linux64 SDK over that profile. (One-time GUI step.)

## 1. Build the Linux64 binary + image + tar (one command)

With the SDK + PAServer set up and Docker available:

```powershell
powershell -ExecutionPolicy Bypass -File deploy\docker\build.ps1
```
This (1) compiles Linux64 (Release), (2) strips + stages the `IPTVPlayService`
binary, (3) builds `iptvplay:latest`, and (4) exports it to **`iptvplay.tar.gz`**
(repo root) ready to copy to Unraid. It auto-detects **Docker Desktop** *or*
**docker inside WSL2** (no Desktop needed — it copies the small build context to
`C:\Temp` so WSL can read it). Options: `-Config Debug`, `-Bds "<dir>"`,
`-Tag myname:tag`, `-SaveTo "<path>"`, `-WslDistro Ubuntu`, `-SkipBuild`
(reuse a staged binary), `-SkipDocker`, `-NoSave`.

The image is intentionally minimal: a trimmed `debian:bookworm-slim` (glibc — a
Delphi Linux64 requirement, so Alpine/musl is out) with only `libcurl4` +
`ca-certificates` + `tzdata`, and the binary stripped of debug symbols.

### …or manually

- Open `backend/src/host_service/IPTVPlayService.dproj`, **Target Platform =
  Linux64**, Config = Release, **Build** → binary lands in
  `.Output\Linux64\Release\IPTVPlayService`.
- Copy that binary **next to this Dockerfile**, then:

```bash
cd deploy/docker
docker build -t iptvplay:latest .
```

## 3. Run

```bash
docker compose up -d        # uses docker-compose.yml
# or plain docker:
docker run -d --name iptvplay -p 7777:7777 \
  -v $PWD/data:/opt/iptvplay/data \
  -v $PWD/config.json:/opt/iptvplay/config.json:ro \
  -e TZ=Europe/Amsterdam iptvplay:latest
```

Logs: `docker logs -f iptvplay` (the daemon writes to stdout). Stop is clean —
`docker stop` sends SIGTERM, which the daemon handles to shut down the MARS HTTP
server + the scheduler.

## Unraid

The easiest path uses the bundled template **`iptv-gateway.xml`**:

1. Build + export on your dev box: `build.ps1` → `iptvplay.tar.gz`.
2. Copy the tar to Unraid and load it: `docker load -i iptvplay.tar.gz`
   (→ `Loaded image: iptvplay:latest`). No registry needed.
3. Install the template: copy `iptv-gateway.xml` to
   `/boot/config/plugins/dockerMan/templates-user/my-IPTV-Gateway.xml`.
4. Docker tab → **Add Container** → Template **IPTV-Gateway** → Apply.
5. **Before first start**, create the config FILE on the host (a missing
   single-file mount becomes a directory): `mkdir -p
   /mnt/user/appdata/iptv-gateway/data && cp config.json
   /mnt/user/appdata/iptv-gateway/config.json`.
6. Set the **Admin password** variable (`ADMIN_PASSWORD`) in the template to lock
   the admin UI/API. Empty = open (LAN only). It overrides `adminPassword` in
   config.json and does NOT affect the Xtream box endpoints (those use their own
   output credentials). Expose the admin port over HTTPS if reachable externally.

Manual alternative (without the template):

- Add a container from this image (or use Community Apps → Docker Compose).
- Map host port → `7777` (and `7778` only if you enable the stream proxy; plus
  UDP `1900` only if you want Plex HDHomeRun auto-discovery, which needs host
  networking anyway).
- Bind two paths:
  - `/opt/iptvplay/data` → an appdata folder (keeps the SQLite db).
  - `/opt/iptvplay/config.json` → your config file, **read-write** (the Settings
    screen and the proxy toggle rewrite it; a read-only mount makes those fail).
- Set `TZ` so the daily refresh fires at the right local time.
- Point your IPTV box at `http://<unraid-ip>:7777` (Xtream) or
  `http://<unraid-ip>:7777/get.php?...` (M3U). For HTTPS, mount certs, set
  `useHttps`/`tlsCertFile`/`tlsKeyFile` in config.json, and expose 7777 over TLS.

## Notes

- The SQLite engine is statically linked into the binary — no sqlite package needed.
- `libcurl4` + `openssl` are installed for HTTP(S) fetches and the TLS output portal.
- The image expects glibc-compatible Linux64 output (Debian/Ubuntu), which is
  what RAD Studio's Linux64 target produces.
