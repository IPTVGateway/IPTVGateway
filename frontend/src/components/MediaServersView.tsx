import { useCallback, useEffect, useRef, useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { AppConfig, CustomList, MediaGroup, MediaStatus } from '../types'
import { useT } from '../i18n'

// Input ranges + shown defaults (when the config has no value) of the numeric settings.
const DUMMY_EPG_BLOCK_MINUTES = { min: 5, max: 720, def: 120 }
const DUMMY_EPG_HOURS_BACK = { min: 0, max: 168, def: 12 } // up to a week back
const DUMMY_EPG_HOURS_AHEAD = { min: 1, max: 336, def: 48 } // up to two weeks ahead
const PLEX_TUNER_COUNT = { min: 1, max: 32, def: 4 }
// how long the "Copied ✓" feedback stays
const COPIED_FEEDBACK_MS = 1500

/**
 * "Media Servers" tab: everything Plex/Jellyfin. A single GLOBAL group filter
 * (which M3U group-titles are published on the existing root endpoints), the base
 * URL, dummy-EPG settings and the HDHomeRun tuner count — plus one set of
 * copyable URLs for Plex and Jellyfin. There are no per-tuner lineups: the filter
 * applies to the Plex bouquet's M3U, XMLTV and lineup.json (boxes are unfiltered).
 */
export function MediaServersView() {
  const t = useT()
  const [cfg, setCfg] = useState<AppConfig | null>(null)
  const [groups, setGroups] = useState<MediaGroup[]>([])
  const [lists, setLists] = useState<CustomList[]>([])
  const [status, setStatus] = useState<MediaStatus | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  const [rescanMsg, setRescanMsg] = useState<string | null>(null)
  const [deviceMsg, setDeviceMsg] = useState<string | null>(null)

  const refreshStatus = useCallback(() => {
    api.mediaStatus().then(setStatus).catch(() => setStatus(null))
  }, [])

  useEffect(() => {
    api.getConfig().then(setCfg).catch((e) => setError((e as Error).message))
    api.mediaGroups().then(setGroups).catch(() => setGroups([]))
    api.listLists().then(setLists).catch(() => setLists([]))
    refreshStatus()
  }, [refreshStatus])

  function patch(p: Partial<AppConfig>) {
    setCfg((c) => (c ? { ...c, ...p } : c))
    setSaved(false)
  }

  const selected = new Set(cfg?.visibleGroups ?? [])
  function toggleGroup(name: string, on: boolean) {
    // empty filter means "all" — materialise the full set on first change so
    // unchecking one narrows from everything rather than no-op'ing
    const base = selected.size === 0 ? new Set(groups.map((g) => g.name)) : new Set(selected)
    if (on) base.add(name)
    else base.delete(name)
    // re-selecting everything collapses back to "empty = publish all"
    patch({ visibleGroups: base.size === groups.length ? [] : [...base] })
  }

  // Base URL used to build the copyable links: the configured one, else the
  // browser's origin (which mirrors the backend's Host-header fallback).
  const base = (cfg?.publicBaseUrl?.trim().replace(/\/+$/, '') || window.location.origin)
  const urls = {
    plexDiscover: `${base}/discover.json`,
    guide: `${base}/plex/epg.xml`,
    jellyfinM3u: `${base}/plex/playlist.m3u`,
  }

  function validBaseUrl(v: string): boolean {
    const s = v.trim()
    return s === '' || /^https?:\/\/.+/i.test(s)
  }

  async function save(e: FormEvent) {
    e.preventDefault()
    if (!cfg) return
    if (!validBaseUrl(cfg.publicBaseUrl ?? '')) {
      setError(t('Base URL must start with http:// or https:// (or be empty).'))
      return
    }
    setBusy(true)
    setError(null)
    try {
      const next = await api.saveConfig({
        publicBaseUrl: (cfg.publicBaseUrl ?? '').trim().replace(/\/+$/, ''),
        visibleGroups: cfg.visibleGroups ?? [],
        dummyEpgEnabled: cfg.dummyEpgEnabled,
        dummyEpgBlockMinutes: cfg.dummyEpgBlockMinutes,
        dummyEpgHoursBack: cfg.dummyEpgHoursBack,
        dummyEpgHoursAhead: cfg.dummyEpgHoursAhead,
        nameShowGroup: cfg.nameShowGroup,
        nameShowNumber: cfg.nameShowNumber,
        nameShowSource: cfg.nameShowSource,
        idSortPrefix: cfg.idSortPrefix,
        plexM3uEnabled: cfg.plexM3uEnabled,
        plexM3uProxy: cfg.plexM3uProxy,
        plexHdhrEnabled: cfg.plexHdhrEnabled,
        plexHdhrProxy: cfg.plexHdhrProxy,
        plexTunerCount: cfg.plexTunerCount,
        plexListId: cfg.plexListId ?? 0,
        plexServerUrl: cfg.plexServerUrl,
        plexToken: cfg.plexToken,
      })
      setCfg(next)
      setSaved(true)
      // the group list belongs to the Plex bouquet — re-read it (it may have changed)
      api.mediaGroups().then(setGroups).catch(() => setGroups([]))
      refreshStatus() // status reflects the newly-saved filter
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function resetDeviceId() {
    setDeviceMsg(null)
    setError(null)
    try {
      const r = await api.resetDeviceId()
      patch({ plexDeviceId: r.deviceId })
      setDeviceMsg(
        t('New DeviceID: {id} — now remove and re-add the DVR in Plex.').replace('{id}', r.deviceId),
      )
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function rescanPlex() {
    setRescanMsg(null)
    setError(null)
    try {
      const r = await api.plexRescan()
      setRescanMsg(
        t('Plex rescan started ({dvrs} {dvrWord}).')
          .replace('{dvrs}', String(r.dvrs))
          .replace('{dvrWord}', r.dvrs === 1 ? t('DVR') : t('DVRs')),
      )
    } catch (e) {
      setError((e as Error).message)
    }
  }

  if (!cfg) {
    return (
      <section className="panel settings-card">
        <header className="panel-head">
          <h2>{t('Media Servers')}</h2>
        </header>
        <div className="panel-body">
          {error ? <p className="error">{error}</p> : <p className="muted">{t('Loading…')}</p>}
        </div>
      </section>
    )
  }

  const allSelected = selected.size === 0
  return (
    <div className="settings-view">
      <form className="settings-form" onSubmit={save}>
        {error && <p className="error">{error}</p>}

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Media Servers')}</h2>
          </header>
          <div className="panel-body">
            <fieldset>
              <legend>{t('Base URL')}</legend>
              <label className="inline">
                {t('Base URL')}
                <input
                  placeholder="http://192.168.1.50:7777"
                  value={cfg.publicBaseUrl ?? ''}
                  onChange={(e) => patch({ publicBaseUrl: e.target.value })}
                  style={{ minWidth: 280 }}
                />
              </label>
              <span className="hint">
                {t('Used to build the tuner URLs below. Leave empty to use whatever host the request came in on.')}
              </span>
            </fieldset>
          </div>
        </section>

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Channel filter')}</h2>
          </header>
          <div className="panel-body">
            <span className="hint">
              {t('Publish only these groups of the Plex bouquet to Plex/Jellyfin (M3U, XMLTV and HDHomeRun lineup). Select none to publish everything. Boxes always get their whole bouquet.')}
            </span>
            <div className="form-actions">
              <button type="button" onClick={() => patch({ visibleGroups: [] })} disabled={allSelected}>
                {t('Publish all groups')}
              </button>
            </div>
            {groups.length === 0 ? (
              <p className="muted">{t('No groups yet — pick channels onto the default list first.')}</p>
            ) : (
              <div className="group-checks">
                {groups.map((g) => (
                  <label className="inline" key={g.name}>
                    <input
                      type="checkbox"
                      checked={allSelected || selected.has(g.name)}
                      onChange={(e) => toggleGroup(g.name, e.target.checked)}
                    />
                    {g.name || t('(no group)')} <span className="muted">({g.channels})</span>
                  </label>
                ))}
              </div>
            )}
            {status && (
              <span className="hint">
                {t('Published now: {ch} channels — {real} with real EPG, {dummy} dummy.')
                  .replace('{ch}', String(status.channels))
                  .replace('{real}', String(status.realEpg))
                  .replace('{dummy}', String(status.dummyEpg))}
              </span>
            )}
          </div>
        </section>

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Dummy EPG')}</h2>
          </header>
          <div className="panel-body">
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.dummyEpgEnabled ?? true}
                onChange={(e) => patch({ dummyEpgEnabled: e.target.checked })}
              />
              {t('Fill channels without real guide data with dummy programmes')}
            </label>
            <span className="hint">
              {t('Stops Plex/Jellyfin showing “Unknown airing”. Channels with real EPG are left untouched.')}
            </span>
            <label className="inline">
              {t('Block length (minutes)')}
              <input
                type="number"
                min={DUMMY_EPG_BLOCK_MINUTES.min}
                max={DUMMY_EPG_BLOCK_MINUTES.max}
                value={cfg.dummyEpgBlockMinutes ?? DUMMY_EPG_BLOCK_MINUTES.def}
                disabled={!cfg.dummyEpgEnabled}
                onChange={(e) =>
                  patch({
                    dummyEpgBlockMinutes: clamp(e.target.value, DUMMY_EPG_BLOCK_MINUTES.min, DUMMY_EPG_BLOCK_MINUTES.max),
                  })
                }
              />
            </label>
            <label className="inline">
              {t('Window: hours back')}
              <input
                type="number"
                min={DUMMY_EPG_HOURS_BACK.min}
                max={DUMMY_EPG_HOURS_BACK.max}
                value={cfg.dummyEpgHoursBack ?? DUMMY_EPG_HOURS_BACK.def}
                disabled={!cfg.dummyEpgEnabled}
                onChange={(e) =>
                  patch({ dummyEpgHoursBack: clamp(e.target.value, DUMMY_EPG_HOURS_BACK.min, DUMMY_EPG_HOURS_BACK.max) })
                }
              />
            </label>
            <label className="inline">
              {t('Window: hours ahead')}
              <input
                type="number"
                min={DUMMY_EPG_HOURS_AHEAD.min}
                max={DUMMY_EPG_HOURS_AHEAD.max}
                value={cfg.dummyEpgHoursAhead ?? DUMMY_EPG_HOURS_AHEAD.def}
                disabled={!cfg.dummyEpgEnabled}
                onChange={(e) =>
                  patch({ dummyEpgHoursAhead: clamp(e.target.value, DUMMY_EPG_HOURS_AHEAD.min, DUMMY_EPG_HOURS_AHEAD.max) })
                }
              />
            </label>
          </div>
        </section>

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Plex / Jellyfin tuners')}</h2>
          </header>
          <div className="panel-body">
            <label>
              {t('Bouquet for Plex / Jellyfin')}
              <select
                value={cfg.plexListId ?? 0}
                // the group filter names groups of the CURRENT bouquet — reset it
                // (= publish everything) when switching bouquets
                onChange={(e) => patch({ plexListId: Number(e.target.value), visibleGroups: [] })}
              >
                <option value={0}>{t('First enabled bouquet (default)')}</option>
                {lists.map((l) => (
                  <option key={l.id} value={l.id} disabled={!l.enabled}>
                    {l.name}
                    {l.enabled ? '' : ` (${t('disabled')})`}
                  </option>
                ))}
              </select>
            </label>
            <span className="hint">
              {t('Plex and Jellyfin can’t log in, so they get this bouquet. Your boxes keep their own bouquet via their username/password. After switching, have Plex rescan.')}
            </span>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.plexM3uEnabled ?? false}
                onChange={(e) => patch({ plexM3uEnabled: e.target.checked })}
              />
              {t('Enable M3U + XMLTV tuner (Jellyfin, or Plex “M3U tuner”)')}
            </label>
            <label className="inline sub">
              <input
                type="checkbox"
                checked={cfg.plexM3uProxy ?? false}
                disabled={!cfg.plexM3uEnabled}
                onChange={(e) => patch({ plexM3uProxy: e.target.checked })}
              />
              {t('stream via proxy (otherwise direct)')}
            </label>

            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.plexHdhrEnabled ?? false}
                onChange={(e) => patch({ plexHdhrEnabled: e.target.checked })}
              />
              {t('Enable HDHomeRun tuner + auto-discovery (Plex, SSDP)')}
            </label>
            <label className="inline sub">
              <input
                type="checkbox"
                checked={cfg.plexHdhrProxy ?? false}
                disabled={!cfg.plexHdhrEnabled}
                onChange={(e) => patch({ plexHdhrProxy: e.target.checked })}
              />
              {t('stream via proxy (otherwise direct)')}
            </label>
            <label className="inline sub">
              {t('Tuners (concurrent streams)')}
              <input
                type="number"
                min={PLEX_TUNER_COUNT.min}
                max={PLEX_TUNER_COUNT.max}
                value={cfg.plexTunerCount ?? PLEX_TUNER_COUNT.def}
                disabled={!cfg.plexHdhrEnabled}
                onChange={(e) =>
                  patch({ plexTunerCount: clamp(e.target.value, PLEX_TUNER_COUNT.min, PLEX_TUNER_COUNT.max) })
                }
              />
            </label>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.idSortPrefix ?? false}
                onChange={(e) => patch({ idSortPrefix: e.target.checked })}
              />
              {t('Force Plex guide order via the channel-id (recommended)')}
            </label>
            <span className="hint">
              {t('Plex sorts its Live TV guide by the channel-id, not the name — so a name prefix can’t reorder it. This puts a zero-padded number plus the channel name in the channel-id (e.g. “01 NPO 1”) in your bouquet order, so Plex’s guide follows your order. EPG keeps working (the guide ids are re-keyed together); your box output keeps the real ids. After enabling, remove + re-add the DVR in Plex.')}
            </span>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.nameShowSource ?? false}
                onChange={(e) => patch({ nameShowSource: e.target.checked })}
              />
              {t('Show a provider letter in the channel name (groups by provider in Plex)')}
            </label>
            <span className="hint">
              {t('Puts a per-provider letter in front — A = 1st source, B = 2nd, … — e.g. “A NPO 1”, “B HBO”. A leading letter is NOT stripped by Plex the way a leading number is, so Plex actually groups + sorts your channels by provider. Combine with the number for “A 018 NPO 1”.')}
            </span>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.nameShowNumber ?? false}
                onChange={(e) => patch({ nameShowNumber: e.target.checked })}
              />
              {t('Show a sort number in the channel name (forces Plex order)')}
            </label>
            <span className="hint">
              {t('Plex usually sorts Live TV by name. This puts a zero-padded number in front — e.g. “010 NPO 1” — following your exact bouquet order (group order + channel order), so Plex ends up sorted the way you arranged it.')}
            </span>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.nameShowGroup ?? false}
                onChange={(e) => patch({ nameShowGroup: e.target.checked })}
              />
              {t('Show group in the channel name (Plex/HDHomeRun)')}
            </label>
            <span className="hint">
              {t('Plex’s HDHomeRun tuner can’t display groups, so this prefixes each channel with its group — e.g. “Sport · NPO 1” — so you can tell the provider apart. Only affects the Plex/Jellyfin output; your normal box keeps clean names.')}
            </span>
            <span className="hint">
              {t('Both together give e.g. “010 Sport · NPO 1”.')}
            </span>
            <span className="hint">
              {t('Note: the gateway does not pool upstream connections — every playing channel is one connection to the provider, across all media servers. The provider’s max-connections is the real limit.')}
            </span>
          </div>
        </section>

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Tuner URLs')}</h2>
          </header>
          <div className="panel-body">
            <div className="tuner-urls">
              <h3>Plex</h3>
              <CopyUrl label={t('Tuner (discover.json)')} url={urls.plexDiscover} />
              <CopyUrl label={t('Guide (XMLTV)')} url={urls.guide} />
              <h3>Jellyfin</h3>
              <CopyUrl label={t('M3U tuner (playlist.m3u)')} url={urls.jellyfinM3u} />
              <CopyUrl label={t('Guide (XMLTV)')} url={urls.guide} />
            </div>
            {cfg.plexDeviceId && (
              <span className="hint">
                {t('HDHomeRun DeviceID:')} <code>{cfg.plexDeviceId}</code>
              </span>
            )}
            <div className="form-actions">
              <button type="button" onClick={resetDeviceId} disabled={busy}>
                {t('New tuner ID (Plex forgets old numbering)')}
              </button>
              {deviceMsg && <span className="muted">{deviceMsg}</span>}
            </div>
            <span className="hint">
              {t('Use when Plex keeps the wrong channel order after re-adding: this gives the tuner a new DeviceID so Plex sees a brand-new device and re-imports the lineup fresh. Afterwards, remove the DVR in Plex and add it again.')}
            </span>
          </div>
        </section>

        <section className="panel settings-card">
          <header className="panel-head">
            <h2>{t('Plex server (optional)')}</h2>
          </header>
          <div className="panel-body">
            <label>
              {t('Plex server (optional — for the rescan button)')}
              <input
                placeholder="http://192.168.1.10:32400"
                value={cfg.plexServerUrl ?? ''}
                onChange={(e) => patch({ plexServerUrl: e.target.value })}
              />
            </label>
            <label>
              {t('Plex token (X-Plex-Token)')}
              <input value={cfg.plexToken ?? ''} onChange={(e) => patch({ plexToken: e.target.value })} />
            </label>
            <div className="form-actions">
              <button
                type="button"
                onClick={rescanPlex}
                disabled={!cfg.plexServerUrl?.trim() || !cfg.plexToken?.trim()}
                title={t('Have Plex re-read its DVR guide/lineup')}
              >
                {t('Rescan Plex')}
              </button>
              {rescanMsg && <span className="muted">{rescanMsg}</span>}
            </div>
            <span className="hint">
              {t('Save your settings first; the button has Plex re-read the guide + channels after a bouquet change. Find the token via Plex (X-Plex-Token).')}
            </span>
          </div>
        </section>

        <div className="form-actions">
          <button type="submit" disabled={busy}>
            {busy ? t('Saving…') : t('Save settings')}
          </button>
          {saved && <span className="muted">{t('Saved ✓')}</span>}
        </div>
      </form>
    </div>
  )
}

// Copy over http://<lan-ip> too: the async Clipboard API only exists in a secure
// context (HTTPS/localhost), so fall back to a hidden-textarea execCommand('copy'),
// which works on plain HTTP. Returns whether anything landed on the clipboard.
function copyText(text: string): boolean {
  // 1) modern API when available (secure context) — fire and forget
  if (navigator.clipboard && typeof navigator.clipboard.writeText === 'function') {
    navigator.clipboard.writeText(text).catch(() => legacyCopy(text))
    return true
  }
  // 2) legacy fallback (works on http://LAN)
  return legacyCopy(text)
}

function legacyCopy(text: string): boolean {
  try {
    const ta = document.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    ta.style.position = 'fixed'
    ta.style.top = '-1000px'
    ta.style.opacity = '0'
    document.body.appendChild(ta)
    ta.select()
    ta.setSelectionRange(0, text.length)
    const ok = document.execCommand('copy')
    document.body.removeChild(ta)
    return ok
  } catch {
    return false
  }
}

/** One labelled URL with a copy-to-clipboard button + a brief "Copied ✓". */
function CopyUrl({ label, url }: { label: string; url: string }) {
  const t = useT()
  const [copied, setCopied] = useState(false)
  const valueRef = useRef<HTMLElement>(null)
  function copy() {
    if (copyText(url)) {
      setCopied(true)
      setTimeout(() => setCopied(false), COPIED_FEEDBACK_MS)
    } else {
      // last resort: select the text so the user can hit Ctrl+C themselves
      const el = valueRef.current
      if (el) {
        const range = document.createRange()
        range.selectNodeContents(el)
        const sel = window.getSelection()
        sel?.removeAllRanges()
        sel?.addRange(range)
      }
    }
  }
  return (
    <div className="copy-url">
      <span className="copy-url-label">{label}</span>
      <code className="copy-url-value" ref={valueRef}>{url}</code>
      <button type="button" onClick={copy} title={t('Copy to clipboard')}>
        {copied ? t('Copied ✓') : t('Copy')}
      </button>
    </div>
  )
}

function clamp(v: string, lo: number, hi: number): number {
  const n = Number(v)
  if (Number.isNaN(n)) return lo
  return Math.min(hi, Math.max(lo, Math.trunc(n)))
}
