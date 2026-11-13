# Publishing IPTV Gateway for Unraid

This explains how to build the image, push it to a registry, and share it so
Unraid users can install it (e.g. a forum beta with testers).

The published image contains **only the compiled service + the built web UI** —
no source code, no playlists, no provider credentials. Configuration is supplied
at runtime via environment variables and a mounted volume.

> For end users, see the **[User Guide](../../docs/USER-GUIDE.md)** — what the app
> does, every screen, and how to connect a box / Plex. Attach it (or link it) in
> the forum post.

---

## 0. One-time setup

1. **Make a registry account.** Docker Hub (https://hub.docker.com) is the
   simplest for Unraid. Pick a **neutral username** — it becomes part of the
   public image name (`username/iptv-gateway`). Your email is **not** shown to
   others; leave the optional profile fields (real name, etc.) blank to stay
   anonymous beyond the username.
2. **Create a public repository** named e.g. `iptv-gateway`.
3. **Log in to Docker** once (this project's Docker runs inside WSL):
   ```powershell
   wsl -d Ubuntu -u root -- docker login        # Docker Hub
   # or for GHCR:  wsl -d Ubuntu -u root -- docker login ghcr.io
   ```

> Linux/Docker builds need **Delphi Enterprise** (the Linux compiler is not in
> Community/Professional). The Windows build is CE-compatible; only this Linux
> image step needs Enterprise.

---

## 1. Build + push

From the repo root:

```powershell
# build frontend first (so the UI is bundled)
cd frontend; npm run build; cd ..

# build the Linux64 image and push it
powershell -ExecutionPolicy Bypass -File deploy\docker\build.ps1 `
  -Repo youruser/iptv-gateway -Push -Version 1.0.0
```

What this does:
- cross-compiles the Linux64 service (uses `deploy\linux-sysroot`, no RAD Studio
  Linux SDK needed),
- builds the Docker image (debian-slim + binary + web UI),
- `docker push`es `youruser/iptv-gateway:latest` **and** `:1.0.0`,
- writes a ready bundle to `.Output\Docker\` with the Unraid template already
  pointed at `youruser/iptv-gateway:latest`.

Options: `-Repo` (registry repo), `-Version` (extra tag), `-Push` (tag+push),
`-NoSave` (skip the local tar), `-SkipBuild` (reuse the staged binary).

The image is **amd64 only** (Delphi's Linux target is x86-64). That's fine for
Unraid — Unraid only runs on x86-64.

---

## 2. How Unraid users install it

Two pieces: the **image** (in your registry) and the **template** (`iptv-gateway.xml`).

**A. Via the template (recommended for a forum post)**
- Attach `iptv-gateway.xml` to the forum post (or host it in a GitHub repo).
- A user drops it in `/boot/config/plugins/dockerMan/templates-user/` on their
  Unraid box, then **Docker tab → Add Container → Template: IPTV-Gateway**.
- Or they paste the repository name into **Add Container → Repository** manually.

**B. Community Applications (later, for discoverability)**
- Submit the template to the CA templates repo (a GitHub PR) so it shows up in
  the Unraid "Apps" search. Optional; do this once the beta looks good.

### What the user must set
- **Repository**: already filled in (`youruser/iptv-gateway:latest`).
- **Ports**: `7777` (admin UI + Xtream/M3U portal + Plex endpoints), `7778`
  (stream proxy, only used when the proxy is enabled), and UDP `1900` (SSDP, only
  for Plex HDHomeRun auto-discovery — LAN-only, needs host networking).
- **Data volume**: `/opt/iptvplay/data` → e.g. `/mnt/user/appdata/iptv-gateway/data`.
- **config.json**: no separate mount needed. It lives in the Data folder
  (`/opt/iptvplay/data/config.json`) and is created on first start.
- **TZ** and **ADMIN_PASSWORD** env vars.

### Networking / Plex note
- The HTTP endpoints work fine on the default **bridge** network.
- **Plex HDHomeRun auto-discovery (SSDP / UDP 1900) does NOT cross bridge NAT.**
  For auto-detect, set the container's **Network Type = host**; otherwise add the
  tuner in Plex manually by URL (`http://<server-ip>:7777`). Either way set
  `publicBaseUrl` to the real host so Plex can fetch the lineup.

### Going public
- Never port-forward UDP 1900 (LAN-only).
- Serve over HTTPS and set a strong `ADMIN_PASSWORD` before exposing `/api`.

---

## 3. Forum post draft (neutral, copy-paste)

> **IPTV Gateway — merge / filter / rename / sort your IPTV providers into one
> Xtream/M3U portal + EPG (beta, looking for testers)**
>
> A small self-hosted tool to manage the IPTV providers you already have access
> to: aggregate several Xtream/M3U sources, filter & rename channels, build your
> own groups, sort/number them, and republish the result as a single Xtream Codes
> portal + M3U + XMLTV guide. Optional Plex Live TV integration (M3U tuner and
> HDHomeRun emulation). **No content or playlists are included — you point it at
> your own subscriptions.**
>
> **Features:** multi-source merge, per-source content-type toggles & name
> filters, custom groups (★ always-on-top pins), drag-and-drop / A→Z channel
> ordering, per-channel rename / logo / tvg-id, change tracking, daily
> auto-refresh, built-in multi-language web admin UI (English/Dutch + add your
> own), optional stream proxy (for use abroad), settings export/import, Plex tuner
> (M3U + HDHomeRun + SSDP).
>
> **Install:** image `youruser/iptv-gateway` (amd64). Template attached — drop it
> in templates-user and add the container. Set a data volume (config.json is created in it)
> file, TZ and ADMIN_PASSWORD. Open the WebUI on port 7777 (configurable).
>
> **Built with:** ~99% with Claude Code (Anthropic's agentic coding tool), human
> in the loop. Open to feedback.
>
> **Notes:** x86-64 only (matches Unraid). For Plex HDHomeRun auto-discovery use
> host networking, or add the tuner by URL. Streaming never flows through the
> service unless you enable the proxy.
>
> **Full user guide:** (attach `USER-GUIDE.md` or link it here).
>
> Feedback / testers welcome — let me know what breaks!
