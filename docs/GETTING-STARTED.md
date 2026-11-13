# Getting started

A step-by-step guide from a freshly installed gateway to a box that shows **your**
line-up. For every screen in detail, see the [User guide](USER-GUIDE.md).

> **Before you start:** IPTV Gateway does not provide any channels. You need at
> least one IPTV source you are entitled to use: an Xtream Codes login (server,
> username, password) or an M3U playlist URL. See the
> [disclaimer](../README.md#disclaimer).

In the examples, `http://192.168.1.50:7777` is the address of your gateway; replace
it with your own server's IP and port.

**Contents**

1. [Open the web app](#1-open-the-web-app)
2. [Add a source (provider)](#2-add-a-source-provider)
3. [Clean channel names automatically](#3-clean-channel-names-automatically)
4. [Hide what you never want to see (filters)](#4-hide-what-you-never-want-to-see-filters)
5. [Create a bouquet](#5-create-a-bouquet)
6. [Create groups in the bouquet](#6-create-groups-in-the-bouquet)
7. [Add channels to the bouquet](#7-add-channels-to-the-bouquet)
8. [Tidy up the bouquet](#8-tidy-up-the-bouquet)
9. [TV guide (EPG)](#9-tv-guide-epg)
10. [Connect your box](#10-connect-your-box)
11. [Plex Live TV & DVR (optional)](#11-plex-live-tv--dvr-optional)
12. [Keep it up to date](#12-keep-it-up-to-date)
13. [Troubleshooting](#troubleshooting)

---

## 1. Open the web app

1. Browse to `http://<your-server>:7777`.
2. Top right should read **backend: ok**.
3. **Set an admin password**: set the `ADMIN_PASSWORD` variable in the Docker or
   Unraid template (or `adminPassword` in `config.json`) and restart the container.
   The web app then asks for it once. Do this whenever the gateway can be reached
   from outside your home.

The web app has five tabs: **Workbench** (sources, catalog, bouquet), **EPG**,
**Media Servers** (Plex/Jellyfin), **Settings** and **Log**.

![Workbench](screenshots/workbench.png)

The **Workbench** has three panels:

| Left: **Sources** | Middle: **Catalog** | Right: **Bouquet** |
|---|---|---|
| your providers | every channel of every provider | the line-up your boxes will see |

---

## 2. Add a source (provider)

1. **Workbench** → left panel → **Add source**.
2. Fill in:

   | Field | What to enter |
   |---|---|
   | **Name** | Anything, e.g. `Provider A`. Shown as a small label next to each channel. |
   | **Kind** | `Xtream` (server + username + password) or `M3U` (a playlist URL). |
   | **URL** | Xtream: the server, e.g. `http://provider.example:8080`. M3U: the full playlist URL. |
   | **Username / Password** | Xtream only, from your provider. |
   | **Live / Movies / Series / Radio** | Tick only what you need, e.g. **Live** only for TV channels. Fewer types means a faster, smaller refresh. |

3. Click **Save**. The gateway reads the provider's channel list. The source card
   shows **Ingesting…** and then **Done: N streams, N groups**. It also shows the
   account's expiry date and maximum number of connections.
4. Repeat for other providers. All channels end up in one catalog, and one bouquet
   can mix channels from several providers.

> **A refresh fails with an HTTP error?** Some providers only accept certain apps.
> Edit the source and set **User-Agent** to `VLC/3.0.21 LibVLC/3.0.21`.

---

## 3. Clean channel names automatically

Providers decorate names, for example `NL | NPO 1 HD`, `┃NL┃ RTL 4 ⏺ʳᵉᶜ` or
`HISTORY ʀᴀᴡ (S)`. You want `NPO 1`, `RTL 4` and `HISTORY ʀᴀᴡ`. Set this **per
source, before you add channels**:

1. Click **Edit** on the source.
2. **Strip prefixes**: the leading tokens to remove, separated by `;`, for example
   `NL`. This turns `NL| NPO 1`, `|NL|`, `┃NL┃` and `NL - NPO 1` into `NPO 1`.
3. **Strip suffixes**: the trailing tokens to remove, for example `(S);rec`. This
   turns `HISTORY ʀᴀᴡ (S)` into `HISTORY ʀᴀᴡ`.
4. **Save**.

From now on every channel you add to a bouquet gets the clean name. Matching ignores
case and understands decorative letters: `ʀᴀᴡ` matches `raw`, and `ʳᵉᶜ` matches
`rec`.

**Already added channels?**
- **Strip prefixes (all)** (left panel, top) re-applies the current rules of every
  source to every channel already in a bouquet.
- Or clean **one group**: click **✂** in the group's header. The dialog shows a
  **Preview** of old → new names. You can add one-off **Extra prefixes / Extra
  suffixes** for that group only, then click **Apply (n)**.
- You can always type a name yourself (see [step 8](#8-tidy-up-the-bouquet)).

The **original provider name** stays visible in small text under the clean name, so
you always know which stream it is.

---

## 4. Hide what you never want to see (filters)

A provider can have tens of thousands of channels. Filters make the catalog short.
They **never delete** anything: change the filter and the channels come back.

1. **Edit** the source → **Name filters**.
2. **Include filters**: keep only channels whose name starts or ends with one of
   these tokens, for example `NL` and `BE` to keep only Dutch and Belgian channels.
   Leave it empty to keep everything.
3. **Exclude filters**: drop channels that start or end with one of these, for
   example `XXX`, `PPV` or `24/7`.
4. **Discovered prefixes** lists the prefixes the provider actually uses, with how
   many channels each has. Tick them instead of typing.
5. **Save**. The catalog now only shows what passes the filters.

> **Filters or strip rules?** Filters decide **which** channels you see. Strip rules
> decide **how their names look** once they are in your bouquet. You usually want
> both: include `NL`, and strip `NL`.

---

## 5. Create a bouquet

A **bouquet** (output list) is the line-up a box sees. Every bouquet has **its own
login**: a box logs in with that username and password as if the gateway were an
ordinary IPTV provider.

1. **Settings** → **Output lists** → in the **List** picker choose **➕ New list…**.
2. Enter:
   - **Name**: for you, e.g. `Living room`.
   - **Username** and **Password**: what the box will use, e.g. `living` and a
     password.
   - **Enabled**: on.
3. Click **Add list**.

**Several bouquets?** Make one per need, for example `Living room` (everything),
`Kids` (only children's channels) and `Plex`. They all draw from the same catalog;
each has its own groups, names and numbers.

**Boxes that should look the same** simply use the **same** bouquet login.

To **change** a login later: choose the bouquet in the picker, edit, and click
**Save**. Boxes then need the new password.

> A bouquet with an **empty username** is the default for boxes that log in without
> (or with unknown) credentials. Only use that when the gateway is not reachable
> from the internet.

---

## 6. Create groups in the bouquet

Groups are the categories on your box, such as `Nederland`, `Sport` or `Movies`.

1. **Workbench** → right panel (**Bouquet**). Choose your bouquet in the picker at
   the top.
2. Type a name in **New group name**, and tick **Favorite** if this group should
   always be at the top.
3. Click **Add group**.

In the header of every group:

| Button | What it does |
|---|---|
| **⠿** (drag) | Move the group up or down; boxes show the groups in this order. |
| **▾** | Collapse or expand the group (only in the web app). |
| **★** | Mark or unmark as favourite. Favourites are pinned to the top on every box. |
| **✎** | Rename the group. |
| **A↓Z** | Sort the group's channels alphabetically and renumber them. |
| **⎘±** | Replace the whole group with another quality or provider, e.g. all HD → 4K (see [step 8](#8-tidy-up-the-bouquet)). |
| **✂** | Clean the channel names in this group (see [step 3](#3-clean-channel-names-automatically)). |
| **🧹** | Empty the group: remove all its channels but keep the group. |
| **🗑** | Delete the group. Its channels move to **Upstream group**. |

**Upstream group** is not a real group. It holds channels that are in the bouquet
but not in one of your groups, and the box then shows them under the provider's own
group name. Move them into your own groups to keep things tidy.

---

## 7. Add channels to the bouquet

1. **Workbench** → middle panel (**Catalog**).
2. Find channels in one of these ways:
   - choose a **source** and **live**, then click a **group** of the provider
     (e.g. `NL | SPORT`) to see its channels, and use **← Back to groups** to go
     back;
   - or type in **Search (contains)…**, e.g. `ziggo`, for a flat list from all
     sources;
   - or use **Prefix (e.g. NL:)** for everything that starts with it;
   - **Only new** shows what the provider added since you last looked. Clear the
     "new" badges with **Mark selected as seen** or **Mark all groups seen**.
3. **Tick** the channels you want, or use **Select all on this page**.
4. Under **Add to**, choose:
   - the **bouquet** (e.g. `Living room`);
   - the **group** (e.g. `Sport`), or **Upstream group** to sort them out later.
5. Click **Add … → Sport**. The channels appear in the bouquet with their clean
   names.

**Good to know:**
- A channel can be in a bouquet **only once**. To move it, change its group in the
  bouquet (step 8).
- You can mix providers in one group, for example NPO from one provider and sport
  from another. The box never knows the difference.
- **📊** next to a catalog channel measures its quality variants (resolution, fps,
  bitrate) before you choose one.

---

## 8. Tidy up the bouquet

Every channel in the bouquet is a row with its own settings:

| Field | What it does |
|---|---|
| **Number** | The channel number on the box. |
| **Name** | The name on the box. Empty means the cleaned provider name; the original stays visible under it. |
| *source label* | Which provider the stream comes from. |
| **⟲ 3d** | The provider keeps an archive (catch-up) of this channel for 3 days. |
| **Logo override URL** | Your own logo instead of the provider's. |
| **tvg-id** | The guide id. Empty means the provider's; pick another if the guide is missing or wrong (see [step 9](#9-tv-guide-epg)). |
| **Group** | Move the channel to another group. |
| **📊** | Measure all quality variants of this channel and switch with **Use this**. |
| **Save** | Store your changes to this row. |
| **🗑** | Remove the channel from the bouquet. |

**Order and numbers**
- **Drag** channels within a group, or click **A↓Z**.
- **Renumber bouquet** (top of the right panel) numbers everything at once: each
  group starts on its own hundred (100, 200, …, or a new thousand for a group with
  more than 99 channels). You get a preview first. The numbers are the same on every
  box and in Plex.

**Better quality in one go**
In a group's header, click **⎘±** and choose a target quality, for example `4K` or
`ʀᴀᴡ`, or another provider. You get a list of matching channels to review. The
channels are swapped **in place**: numbers, names, logos and tvg-ids stay.

**Clean-up**
- **Dedupe** removes duplicate channels (the same stream twice).
- **Sort: Name / No.** changes how the web app lists channels (not the boxes).
- **Collapse all** folds all groups.

---

## 9. TV guide (EPG)

1. **EPG** tab → **⟳ Update EPG**. The gateway fetches the guide of every provider
   for the channels in your bouquets. Only those, so it stays small.
2. Check the grid. It opens at the current time and shows every bouquet channel.
3. **A better guide (recommended):** **Settings** → **Extra EPG sources** → paste one
   XMLTV address per line (for example a country guide; `.xml` or `.xml.gz`) →
   **Save settings** → **⟳ Update EPG**.
   - Channels are matched automatically by name or tvg-id ("NL | NPO 1 HD" matches
     "NPO 1").
   - The extra guide goes first. If a provider's own guide is better, edit that
     source and tick **Own EPG before the extra EPG source**.
   - Channel ids and numbers don't change, so your boxes and Plex keep working
     without re-mapping.
4. **A channel without a guide?** In the bouquet, click **Suggest EPG-ids** and pick
   a suggestion, or type a tvg-id in the channel's **tvg-id** field and click
   **Save**.

The guide refreshes automatically every night. Set the time under **Settings →
Daily refresh**.

---

## 10. Connect your box

### A. As an Xtream Codes portal (recommended)

This works with TiviMate, IPTV Smarters, OTT Navigator, Formuler/MyTVOnline, MAG apps
and others. Add a playlist or portal of type **Xtream Codes (API)**:

| Field | Value |
|---|---|
| Server / URL | `http://192.168.1.50:7777` |
| Username | the bouquet username (step 5) |
| Password | the bouquet password (step 5) |

The box gets your groups, channel order, numbers, names, logos and the guide. On
supporting apps it also gets catch-up: programmes with ⟲ can be replayed.

### B. As an M3U playlist

For apps without Xtream support:

| | URL |
|---|---|
| Playlist | `http://192.168.1.50:7777/get.php?username=<user>&password=<pass>&type=m3u_plus&output=ts` |
| Guide (EPG) | `http://192.168.1.50:7777/xmltv.php?username=<user>&password=<pass>` |

**Changes you make later** (names, order, new channels) reach the box on its next
refresh. Some apps need a manual "refresh playlist" or "update EPG", and some cache
the guide for up to a day.

---

## 11. Plex Live TV & DVR (optional)

1. **Media Servers** tab → **Bouquet for Plex / Jellyfin**: choose a bouquet, for
   example a dedicated `Plex` bouquet.
2. Tick **Enable HDHomeRun tuner + auto-discovery**, and set **Base URL** to the
   gateway's address (e.g. `http://192.168.1.50:7777`).
3. In Plex: **Settings → Live TV & DVR → Set up Plex DVR**. Plex finds the tuner
   automatically, or you add it by its address.
4. Guide: choose **"Have an XMLTV guide on your server"** and use
   `http://192.168.1.50:7777/plex/epg.xml`.
5. If channels don't play in Plex, tick **stream via proxy** for the tuner.

**Notes:**
- Auto-discovery needs **host networking** for the container (SSDP on UDP 1900).
  With bridge networking, add the tuner by its URL.
- **Force Plex guide order via the channel-id** (on by default) makes Plex follow
  your bouquet order.
- Plex has no catch-up of the provider's archive. Use its DVR to record instead.
- After adding or removing channels, let Plex rescan its guide.

---

## 12. Keep it up to date

- **Unraid:** with the template repository `ghcr.io/iptvgateway/iptvgateway:latest`,
  a new version shows up as **update ready** on the Docker tab. One click updates it.
  Your settings and data in `/data` are kept.
- **Docker:** `docker compose pull && docker compose up -d`.

---

## Troubleshooting

| Problem | What to check |
|---|---|
| Box says "login failed" | Server URL incl. port, and the bouquet username and password (case-sensitive). Is the bouquet **Enabled** in Settings → Output lists? |
| A channel doesn't play | Does it play directly from your provider? Many providers allow only one or two connections at a time. Try another quality variant (📊). |
| Names still show "NL \|" | The strip rules apply when channels are **added**. For channels already in the bouquet, use **Strip prefixes (all)** or the group's **✂**. |
| Catalog shows thousands of channels you don't want | Set **Include filters** on the source (step 4). |
| No guide for a channel | **EPG → ⟳ Update EPG**; add an **extra EPG source**; set a tvg-id. On the box, "update EPG". |
| A source fails to refresh | Set the source's **User-Agent** to `VLC/3.0.21 LibVLC/3.0.21`; check the expiry date on the source card. |
| Something else | **Log** tab → type a word in the filter (`failed`, `timeshift`, a channel name) → **Download** to share it. |
