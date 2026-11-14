import { LogView } from './components/LogView'
import { useCallback, useEffect, useRef, useState } from 'react'
import { api, adminAuth, setUnauthorizedHandler, TooManyRequestsError, UnauthorizedError } from './api/client'
import { LoginGate } from './components/LoginGate'
import { AccessBlocked } from './components/AccessBlocked'
import { accessBlock, type AccessBlock } from './lib/errors'
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
  const v = Number(safeGetItem(key))
  return Number.isFinite(v) && v > 0 ? v : def
}
import { applyTheme, initTheme, readTheme, writeTheme, type ThemePref } from './lib/theme'
import { safeGetItem, safeSetItem } from './lib/storage'

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
  // seconds of a failed-login lockout (429) the initial probe ran into (0 = none)
  const [lockedForSec, setLockedForSec] = useState(0)
  // the admin API refused this browser (403: no admin password + not on the LAN,
  // or a Host that is not allowed): a full-page notice instead of a broken workbench
  const [blocked, setBlocked] = useState<AccessBlock | null>(null)
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
  useEffect(() => safeSetItem(LEFT_W_KEY, String(leftW)), [leftW])
  useEffect(() => safeSetItem(RIGHT_W_KEY, String(rightW)), [rightW])

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
        if (!cancelled && !(e instanceof UnauthorizedError) && !(e instanceof TooManyRequestsError))
          setHealth(`unreachable: ${(e as Error).message}`)
      })
    api
      .getConfig()
      .then(() => {
        if (!cancelled) setAuthed(true)
      })
      .catch((e) => {
        if (cancelled) return
        // locked out after too many failed logins: the login gate, in its locked state
        if (e instanceof TooManyRequestsError) {
          setLockedForSec(e.retryAfterSec)
          setAuthed(false)
          return
        }
        // refused by the LAN / Host guard: not "in" — say why and what to do
        const block = accessBlock(e)
        if (block) {
          setBlocked(block)
          setAuthed(false)
          return
        }
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
      setView('mediaservers') // no Plex server/token yet: that's where they're set
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
    if (loadedListIdRef.current !== activeListId) {
      // switching lists: drop the previous list's data up front, so a failed load
      // can't leave list A's groups/items acting as list B's
      loadedListIdRef.current = null
      setGroups([])
      setItems([])
      setListLoading(true)
    }
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

  if (blocked) return <AccessBlocked block={blocked} />
  if (authed === null) {
    return <div className="app-checking muted">{t('Connecting…')}</div>
  }
  if (authed === false) {
    return (
      <LoginGate
        lockedForSec={lockedForSec}
        onAuthed={() => {
          setLockedForSec(0)
          setAuthed(true)
        }}
      />
    )
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
                ? t('The Plex bouquet changed — update the channels and guide in Plex')
                : t('Bouquet changed — set the Plex server/token (Media Servers), or scan manually in Plex')
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
                sources={sources}
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
