import { LogView } from './components/LogView'
import { useCallback, useEffect, useRef, useState } from 'react'
import { api, adminAuth, setUnauthorizedHandler, UnauthorizedError } from './api/client'
import { LoginGate } from './components/LoginGate'
import type { CustomGroup, CustomItem, CustomList, Source } from './types'
import { SourcesPanel } from './components/SourcesPanel'
import { CatalogPanel } from './components/CatalogPanel'
import { ListPanel } from './components/ListPanel'
import { EpgView } from './components/EpgView'
import { SettingsView } from './components/SettingsView'
import { MediaServersView } from './components/MediaServersView'
import { Splitter } from './components/Splitter'
import { useI18n, useT } from './i18n'

// Resizable workbench columns: localStorage keys, defaults and drag limits (px).
const LEFT_W_KEY = 'iptvplay_leftW'
const RIGHT_W_KEY = 'iptvplay_rightW'
const LEFT_W_DEFAULT = 320
const RIGHT_W_DEFAULT = 380
const LEFT_W_MIN = 240
const LEFT_W_MAX = 640
const RIGHT_W_MIN = 280
const RIGHT_W_MAX = 900
// how often the header re-checks whether a Plex rescan is due
const PLEX_STATUS_POLL_MS = 20_000
// /api/health status of a healthy backend
const HEALTH_OK = 'ok'

const clampW = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v))
function loadW(key: string, def: number): number {
  const v = Number(localStorage.getItem(key))
  return Number.isFinite(v) && v > 0 ? v : def
}
import { applyTheme, initTheme, readTheme, writeTheme, type ThemePref } from './lib/theme'

const THEME_OPTIONS: { value: ThemePref; label: string }[] = [
  { value: 'system', label: 'System' },
  { value: 'light', label: 'Light' },
  { value: 'dark', label: 'Dark' },
]

type View = 'workbench' | 'epg' | 'mediaservers' | 'settings' | 'log'
type Pane = 'sources' | 'catalog' | 'list'

const PANES: { value: Pane; label: string }[] = [
  { value: 'sources', label: 'Sources' },
  { value: 'catalog', label: 'Catalog' },
  { value: 'list', label: 'Bouquet' },
]

// Three-panel "merge / filter / rename / sort" workbench:
//   Sources (left) · merged Catalog (middle) · curated List (right).
export function App() {
  const t = useT()
  const { reload: reloadLanguages } = useI18n()
  const [health, setHealth] = useState('checking…')
  const [version, setVersion] = useState('')
  // null = still checking; false = locked (show login); true = in
  const [authed, setAuthed] = useState<boolean | null>(null)
  const [view, setView] = useState<View>('workbench')
  // Which workbench panel is shown on phone/tablet (a single-panel switcher); on
  // wide screens all three show at once and this is ignored.
  const [pane, setPane] = useState<Pane>('catalog')
  const [theme, setTheme] = useState<ThemePref>(() => readTheme())

  const [sources, setSources] = useState<Source[]>([])
  const [lists, setLists] = useState<CustomList[]>([])

  const [activeListId, setActiveListId] = useState<number | null>(null)
  const [groups, setGroups] = useState<CustomGroup[]>([])
  const [items, setItems] = useState<CustomItem[]>([])
  const [listLoading, setListLoading] = useState(false)
  const [listError, setListError] = useState<string | null>(null)

  // Global stream-proxy state (null = not yet known). Toggled from the header.
  const [proxyOn, setProxyOn] = useState<boolean | null>(null)
  const [proxyBusy, setProxyBusy] = useState(false)

  // Plex "rescan due" reminder (null = unknown). Polled; shown in the header when
  // the bouquet changed since the last Plex rescan and a Plex tuner is enabled.
  const [plex, setPlex] = useState<{ pending: boolean; enabled: boolean; configured: boolean } | null>(null)
  const refreshPlex = useCallback(() => {
    api.plexStatus().then(setPlex).catch(() => {})
  }, [])

  // Resizable workbench columns (persisted), so the curated list can be widened.
  const [leftW, setLeftW] = useState(() => loadW(LEFT_W_KEY, LEFT_W_DEFAULT))
  const [rightW, setRightW] = useState(() => loadW(RIGHT_W_KEY, RIGHT_W_DEFAULT))
  useEffect(() => localStorage.setItem(LEFT_W_KEY, String(leftW)), [leftW])
  useEffect(() => localStorage.setItem(RIGHT_W_KEY, String(rightW)), [rightW])

  // any 401 during the session drops us back to the login gate
  useEffect(() => {
    setUnauthorizedHandler(() => setAuthed(false))
    return () => setUnauthorizedHandler(null)
  }, [])

  // initial reachability + auth probe. /api/health is NOT password-protected, so
  // it only gives reachability + version; the stored password is validated
  // against an authenticated endpoint (/api/config): 200 => in; 401 => locked
  // (login screen, no workbench flash); other => reachable-but-down
  useEffect(() => {
    let cancelled = false
    api
      .health()
      .then((h) => {
        if (cancelled) return
        setHealth(h.status)
        if (h.version) setVersion(h.version)
      })
      .catch((e) => {
        if (!cancelled && !(e instanceof UnauthorizedError))
          setHealth(`unreachable: ${(e as Error).message}`)
      })
    api
      .getConfig()
      .then(() => {
        if (!cancelled) setAuthed(true)
      })
      .catch((e) => {
        if (cancelled) return
        // backend down / service not started is not "locked" — let the app load
        setAuthed(!(e instanceof UnauthorizedError))
      })
    return () => {
      cancelled = true
    }
  }, [])

  // add-on UI languages need the admin password: fetch them again once in
  useEffect(() => {
    if (authed === true) reloadLanguages()
  }, [authed, reloadLanguages])

  // once authenticated, load proxy state and refresh the health indicator
  // (the initial probe leaves health on "checking…" when it got a 401)
  // re-read on auth AND whenever the view changes, so the header proxy pill
  // re-syncs after the user flips "Relay streams…" in Settings and navigates away
  useEffect(() => {
    if (authed !== true) return
    api
      .getConfig()
      .then((c) => setProxyOn(c.proxyStreams))
      .catch(() => setProxyOn(null))
    api
      .health()
      .then((h) => setHealth(h.status))
      .catch(() => {})
  }, [authed, view])

  // poll the Plex "rescan due" reminder while signed in
  useEffect(() => {
    if (authed !== true) return
    refreshPlex()
    const t = setInterval(refreshPlex, PLEX_STATUS_POLL_MS)
    return () => clearInterval(t)
  }, [authed, refreshPlex])

  async function plexRescanFromHeader() {
    if (!plex?.configured) {
      setView('settings') // no API token yet — send them to configure / read the hint
      return
    }
    try {
      await api.plexRescan()
    } catch {
      /* error surfaced elsewhere; just refresh state */
    }
    refreshPlex()
  }

  function logout() {
    adminAuth.clear()
    setAuthed(false)
  }

  async function toggleProxy() {
    if (proxyOn == null) return
    setProxyBusy(true)
    try {
      const c = await api.saveConfig({ proxyStreams: !proxyOn })
      setProxyOn(c.proxyStreams)
    } catch {
      /* leave state as-is on failure */
    } finally {
      setProxyBusy(false)
    }
  }

  // Apply theme on mount and keep reacting to OS changes while in 'system' mode.
  useEffect(() => initTheme(theme), [theme])

  function changeTheme(pref: ThemePref) {
    setTheme(pref)
    writeTheme(pref)
    applyTheme(pref)
  }

  const loadSources = useCallback(() => {
    api
      .listSources()
      .then(setSources)
      .catch(() => setSources([]))
  }, [])

  const loadLists = useCallback(() => {
    api
      .listLists()
      .then((ls) => {
        setLists(ls)
        setActiveListId((cur) => {
          // keep the current selection if it still exists; otherwise fall back
          if (cur != null && ls.some((l) => l.id === cur)) return cur
          return ls.length > 0 ? ls[0].id : null
        })
      })
      .catch(() => setLists([]))
  }, [])

  useEffect(() => {
    if (authed !== true) return
    loadSources()
    loadLists()
  }, [authed, loadSources, loadLists])

  // sequence guard: switching lists fast can let an older fetch resolve last and
  // overwrite the newer list's data — only the latest request may apply results.
  const loadSeqRef = useRef(0)
  // the list whose groups/items are currently in state: a refresh of that same
  // list (after any save) must NOT show the "Loading…" placeholder — that would
  // unmount every row, losing unsaved edits elsewhere and the scroll position
  const loadedListIdRef = useRef<number | null>(null)
  const loadActiveList = useCallback(() => {
    if (activeListId == null) {
      loadedListIdRef.current = null
      setGroups([])
      setItems([])
      return
    }
    const seq = ++loadSeqRef.current
    const isStale = () => seq !== loadSeqRef.current
    if (loadedListIdRef.current !== activeListId) setListLoading(true)
    setListError(null)
    Promise.all([api.listGroups(activeListId), api.listItems(activeListId)])
      .then(([g, i]) => {
        if (isStale()) return
        loadedListIdRef.current = activeListId
        setGroups(g)
        setItems(i)
      })
      .catch((e) => {
        if (!isStale()) setListError((e as Error).message)
      })
      .finally(() => {
        if (!isStale()) setListLoading(false)
      })
  }, [activeListId])

  useEffect(() => {
    loadActiveList()
  }, [loadActiveList])

  if (authed === null) {
    return <div className="app-checking muted">{t('Connecting…')}</div>
  }
  if (authed === false) {
    return <LoginGate onAuthed={() => setAuthed(true)} />
  }

  return (
    <div className="app">
      <header className="app-head">
        <h1>
          {t('IPTV Gateway')}
          {version && <span className="app-version" title={t('Running version')}>v{version}</span>}
        </h1>
        <nav className="view-tabs">
          <button
            className={view === 'workbench' ? 'view-tab active' : 'view-tab'}
            onClick={() => setView('workbench')}
          >
            {t('Workbench')}
          </button>
          <button
            className={view === 'epg' ? 'view-tab active' : 'view-tab'}
            onClick={() => setView('epg')}
          >
            {t('EPG')}
          </button>
          <button
            className={view === 'mediaservers' ? 'view-tab active' : 'view-tab'}
            onClick={() => setView('mediaservers')}
          >
            {t('Media Servers')}
          </button>
          <button
            className={view === 'settings' ? 'view-tab active' : 'view-tab'}
            onClick={() => setView('settings')}
          >
            {t('Settings')}
          </button>
          <button
            className={view === 'log' ? 'view-tab active' : 'view-tab'}
            onClick={() => setView('log')}
          >
            {t('Log')}
          </button>
        </nav>
        <div className="segmented theme-switch" role="group" aria-label={t('Theme')}>
          {THEME_OPTIONS.map((o) => (
            <button
              key={o.value}
              type="button"
              className={theme === o.value ? 'seg active' : 'seg'}
              aria-pressed={theme === o.value}
              onClick={() => changeTheme(o.value)}
            >
              {t(o.label)}
            </button>
          ))}
        </div>
        {proxyOn != null && (
          <button
            type="button"
            className={proxyOn ? 'proxy-toggle on' : 'proxy-toggle'}
            onClick={toggleProxy}
            disabled={proxyBusy}
            title={
              proxyOn
                ? t('Stream proxy ON — video is relayed through this server. Click to turn off.')
                : t('Stream proxy OFF — box gets the raw provider URL. Click to relay (e.g. abroad).')
            }
          >
            {t('● Proxy {state}').replace(
              '{state}',
              proxyBusy ? '…' : proxyOn ? t('On') : t('Off'),
            )}
          </button>
        )}
        {plex?.pending && plex.enabled && (
          <button
            type="button"
            className="plex-reminder"
            onClick={plexRescanFromHeader}
            title={
              plex.configured
                ? t('Bouquet changed — have Plex reload the guide/lineup')
                : t('Bouquet changed — set the Plex server/token (Settings), or scan manually in Plex')
            }
          >
            {t('↻ Refresh Plex')}
          </button>
        )}
        <span className={health === HEALTH_OK ? 'health ok' : 'health bad'}>
          {t('backend: {status}').replace('{status}', t(health))}
        </span>
        {adminAuth.get() !== '' && (
          <button type="button" className="logout-btn" onClick={logout} title={t('Log out')}>
            {t('Log out')}
          </button>
        )}
      </header>

      {view === 'log' ? (
        <div className="log-wrap">
          <LogView />
        </div>
      ) : view === 'settings' ? (
        <div className="settings-wrap">
          <SettingsView
            lists={lists}
            onListsChanged={loadLists}
            onImported={() => {
              // an import replaces sources, lists and groups: reload all of it
              loadSources()
              loadLists()
              loadActiveList()
            }}
          />
        </div>
      ) : view === 'mediaservers' ? (
        <div className="settings-wrap">
          <MediaServersView />
        </div>
      ) : view === 'workbench' ? (
        <>
          {/* phone/tablet panel switcher — hidden on wide screens via CSS */}
          <nav className="pane-switch" role="group" aria-label={t('Panel')}>
            {PANES.map((p) => (
              <button
                key={p.value}
                type="button"
                className={pane === p.value ? 'pane-tab active' : 'pane-tab'}
                aria-pressed={pane === p.value}
                onClick={() => setPane(p.value)}
              >
                {t(p.label)}
              </button>
            ))}
          </nav>
          <div
            className={`columns pane-${pane}`}
            style={{
              gridTemplateColumns: `${leftW}px 6px minmax(0, 1fr) 6px ${rightW}px`,
            }}
          >
            <div className="wb-pane wb-sources">
              <SourcesPanel
                onChanged={() => {
                  // a source change (save/refresh) can also re-strip channels already
                  // on the bouquet, and "Strip prefixes (all)" rewrites their names —
                  // so reload the active list too, not just the sources.
                  loadSources()
                  loadActiveList()
                }}
              />
            </div>
            <Splitter onDrag={(dx) => setLeftW((w) => clampW(w + dx, LEFT_W_MIN, LEFT_W_MAX))} />

            <div className="wb-pane wb-catalog">
              <CatalogPanel
                sources={sources}
                lists={lists}
                groups={groups}
                activeListId={activeListId}
                onItemsAdded={loadActiveList}
              />
            </div>

            <Splitter onDrag={(dx) => setRightW((w) => clampW(w - dx, RIGHT_W_MIN, RIGHT_W_MAX))} />
            <div className="wb-pane wb-list">
              <ListPanel
                lists={lists}
                activeListId={activeListId}
                onSelectList={setActiveListId}
                groups={groups}
                items={items}
                loading={listLoading}
                error={listError}
                onRefresh={loadActiveList}
              />
            </div>
          </div>
        </>
      ) : (
        <div className="epg-view-wrap">
          <EpgView lists={lists} activeListId={activeListId} />
        </div>
      )}
    </div>
  )
}
