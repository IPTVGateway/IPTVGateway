import { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { ContentType, IngestStatus, PrefixCount, Source, SourceKind } from '../types'
import { CONTENT_TYPES } from '../lib/ordering'
import { Modal } from './Modal'
import { useT } from '../i18n'

type FilterKind = 'include' | 'exclude'

const TYPE_LABEL: Record<ContentType, string> = {
  live: 'Live',
  movie: 'Movies',
  series: 'Series',
  radio: 'Radio',
}

interface SourceForm {
  id?: number
  name: string
  kind: SourceKind
  url: string
  username: string
  password: string
  epgUrl: string
  userAgent: string
  referer: string
  forceHls: boolean
  preferOwnEpg: boolean
  enabled: boolean
  contentTypes: ContentType[]
  includeFilters: string[]
  excludeFilters: string[]
  stripPrefixes: string // raw comma-separated text; parsed to tokens on save
  stripSuffixes: string // same, for trailing tokens
}

/** Split a ';'-separated token field into trimmed, non-empty tokens. ';' is the
 *  only delimiter, so a single token may itself contain spaces, commas or '|'. */
function parseTokens(raw: string): string[] {
  return raw
    .split(';')
    .map((s) => s.trim())
    .filter((s) => s.length > 0)
}

const EMPTY_FORM: SourceForm = {
  name: '',
  kind: 'xtream',
  url: '',
  username: '',
  password: '',
  epgUrl: '',
  userAgent: '',
  referer: '',
  forceHls: false,
  preferOwnEpg: false,
  enabled: true,
  contentTypes: ['live'],
  includeFilters: [],
  excludeFilters: [],
  stripPrefixes: '',
  stripSuffixes: '',
}

function toForm(s: Source): SourceForm {
  return {
    id: s.id,
    name: s.name,
    kind: s.kind,
    url: s.url,
    username: s.username ?? '',
    password: s.password ?? '',
    epgUrl: s.epgUrl ?? '',
    userAgent: s.userAgent ?? '',
    referer: s.referer ?? '',
    forceHls: s.forceHls ?? false,
    preferOwnEpg: s.preferOwnEpg ?? false,
    enabled: s.enabled,
    contentTypes: [...s.contentTypes],
    includeFilters: [...(s.includeFilters ?? [])],
    excludeFilters: [...(s.excludeFilters ?? [])],
    stripPrefixes: (s.stripPrefixes ?? []).join('; '),
    stripSuffixes: (s.stripSuffixes ?? []).join('; '),
  }
}

interface Props {
  /** Bump to let other panels refresh dependent data when sources change. */
  onChanged?: () => void
}

export function SourcesPanel({ onChanged }: Props) {
  const t = useT()
  const [sources, setSources] = useState<Source[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)
  const [notice, setNotice] = useState<string | null>(null)
  const [busy, setBusy] = useState<string | null>(null)
  const [form, setForm] = useState<SourceForm>(EMPTY_FORM)
  // The add/edit form now lives in a modal so the (busy) sources list stays tidy.
  const [editorOpen, setEditorOpen] = useState(false)
  // Prefixes discovered in the source currently being edited (empty for a new one).
  const [prefixes, setPrefixes] = useState<PrefixCount[]>([])
  const [prefixBusy, setPrefixBusy] = useState(false)
  // which filter list is open in the modal editor (null = closed)
  const [filterModal, setFilterModal] = useState<FilterKind | null>(null)
  // live ingest progress per source id, polled while the panel is open
  const [status, setStatus] = useState<Record<number, IngestStatus>>({})
  const prevRunning = useRef<number[]>([])
  // the 2 s status poll lives for the panel's lifetime: call the LATEST onChanged
  // (the first render's closure would reload a stale/empty active list)
  const onChangedRef = useRef(onChanged)
  onChangedRef.current = onChanged

  useEffect(() => {
    let cancelled = false
    async function poll() {
      try {
        const rows = await api.refreshStatus()
        if (cancelled) return
        const map: Record<number, IngestStatus> = {}
        for (const r of rows) map[r.sourceId] = r
        setStatus(map)
        const running = rows.filter((r) => r.running).map((r) => r.sourceId)
        // a source just finished ingesting → refresh the list + dependent panels
        const justFinished = prevRunning.current.some((id) => !running.includes(id))
        prevRunning.current = running
        if (justFinished) {
          await load()
          onChangedRef.current?.()
        }
      } catch {
        /* ignore transient poll errors */
      }
    }
    void poll()
    const t = setInterval(poll, 2000)
    return () => {
      cancelled = true
      clearInterval(t)
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function load() {
    setLoading(true)
    setError(null)
    try {
      setSources(await api.listSources())
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setLoading(false)
    }
  }

  useEffect(() => {
    void load()
  }, [])

  // When editing an existing source, discover the prefixes in its ingested
  // streams so the user can tick them instead of typing. Re-fetched whenever the
  // edited source changes OR the filter modal (re)opens — so a transient backend
  // hiccup never leaves the picker permanently empty.
  useEffect(() => {
    let cancelled = false
    if (form.id == null) {
      setPrefixes([])
      setPrefixBusy(false) // clear any spinner left from a previous in-flight fetch
      return
    }
    setPrefixBusy(true)
    api
      .sourcePrefixes(form.id)
      .then((p) => {
        if (!cancelled) setPrefixes(p)
      })
      .catch(() => {
        if (!cancelled) setPrefixes([])
      })
      .finally(() => {
        if (!cancelled) setPrefixBusy(false)
      })
    return () => {
      cancelled = true
    }
  }, [form.id, filterModal])

  function notify() {
    onChanged?.()
  }

  // Open the editor modal for a new source, or to edit an existing one.
  function openAdd() {
    setForm(EMPTY_FORM)
    setEditorOpen(true)
  }
  function openEdit(s: Source) {
    setForm(toForm(s))
    setEditorOpen(true)
  }
  function closeEditor() {
    setEditorOpen(false)
    setFilterModal(null)
    setForm(EMPTY_FORM)
  }

  async function toggleType(s: Source, t: ContentType) {
    const next = s.contentTypes.includes(t)
      ? s.contentTypes.filter((x) => x !== t)
      : [...s.contentTypes, t]
    try {
      // send the WHOLE source — a partial body would reset the other columns
      await api.saveSource({ ...s, contentTypes: next })
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function refreshOne(id: number) {
    setBusy(`refresh-${id}`)
    setError(null)
    try {
      await api.refreshSource(id)
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  async function refreshAll() {
    setBusy('refresh-all')
    setError(null)
    try {
      await api.refreshAll()
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  // re-apply every source's strip-prefixes to channels already on lists
  async function restripAll() {
    setBusy('restrip')
    setError(null)
    setNotice(null)
    try {
      const r = await api.restripPrefixes()
      setNotice(t('Stripped prefixes on {n} channels.').replace('{n}', String(r.updated)))
      notify()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  async function remove(id: number) {
    setError(null)
    try {
      await api.deleteSource(id)
      if (form.id === id) closeEditor()
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    }
  }

  async function submit(e: FormEvent) {
    e.preventDefault()
    setBusy('save')
    setError(null)
    try {
      const payload: Partial<Source> = {
        id: form.id,
        name: form.name.trim(),
        kind: form.kind,
        url: form.url.trim(),
        username: form.username.trim(), // '' clears it (undefined would keep the old value)
        password: form.password.trim(), // '' clears it (undefined would keep the old value)
        epgUrl: form.epgUrl.trim(), // '' clears it (undefined would keep the old value)
        userAgent: form.userAgent.trim(), // '' clears it (undefined would keep the old value)
        referer: form.referer.trim(), // '' clears it (undefined would keep the old value)
        forceHls: form.forceHls,
        preferOwnEpg: form.preferOwnEpg,
        enabled: form.enabled,
        contentTypes: form.contentTypes,
        includeFilters: form.includeFilters,
        excludeFilters: form.excludeFilters,
        stripPrefixes: parseTokens(form.stripPrefixes),
        stripSuffixes: parseTokens(form.stripSuffixes),
      }
      await api.saveSource(payload)
      closeEditor()
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  function formToggleType(t: ContentType) {
    setForm((f) => ({
      ...f,
      contentTypes: f.contentTypes.includes(t)
        ? f.contentTypes.filter((x) => x !== t)
        : [...f.contentTypes, t],
    }))
  }

  function setInclude(next: string[]) {
    setForm((f) => ({ ...f, includeFilters: next }))
  }
  function setExclude(next: string[]) {
    setForm((f) => ({ ...f, excludeFilters: next }))
  }

  // Persist the chosen include/exclude filters immediately (used when closing the
  // filter modal). No-op for a not-yet-saved new source.
  async function persistCurrent(override: Partial<SourceForm> = {}) {
    if (form.id == null) return
    const f = { ...form, ...override }
    setError(null)
    try {
      // only the filters: other edits in the form stay unsaved until Save/Cancel
      // (the backend keeps every field that isn't sent)
      await api.saveSource({ id: f.id, includeFilters: f.includeFilters, excludeFilters: f.excludeFilters })
      await load()
      notify()
    } catch (e) {
      setError((e as Error).message)
    }
  }


  // one click: drop BOTH include and exclude filters (and save right away for an
  // existing source — also the way out when a stored filter item is too long)
  function clearFilters() {
    if (!window.confirm(t('Remove all include and exclude filters of this source?'))) return
    setForm((f) => ({ ...f, includeFilters: [], excludeFilters: [] }))
    void persistCurrent({ includeFilters: [], excludeFilters: [] })
  }

  function closeFilterModal() {
    setFilterModal(null)
    void persistCurrent()
  }

  return (
    <section className="panel">
      <header className="panel-head">
        <h2>{t('Sources')}</h2>
        <div className="panel-head-btns">
          <button onClick={openAdd}>{t('Add source')}</button>
          <button
            onClick={restripAll}
            disabled={busy === 'restrip'}
            title={t('Re-apply every source’s strip-prefixes to all channels on your lists (manual renames are kept)')}
          >
            {busy === 'restrip' ? t('Stripping…') : t('Strip prefixes (all)')}
          </button>
          <button onClick={refreshAll} disabled={busy === 'refresh-all'}>
            {busy === 'refresh-all' ? t('Refreshing…') : t('Refresh all')}
          </button>
        </div>
      </header>

      {error && <p className="error">{error}</p>}
      {notice && <p className="muted">{notice}</p>}

      <div className="panel-body">
        {loading ? (
          <p className="muted">{t('Loading…')}</p>
        ) : sources.length === 0 ? (
          <p className="muted">{t('No sources yet.')}</p>
        ) : (
          <ul className="source-list">
            {sources.map((s) => (
              <li key={s.id} className={form.id === s.id ? 'source selected' : 'source'}>
                <div className="source-top">
                  <span className="source-name">{s.name}</span>
                  <span className="badge kind">{s.kind}</span>
                  {!s.enabled && <span className="badge off">{t('disabled')}</span>}
                </div>
                <div className="type-toggles">
                  {CONTENT_TYPES.map((ct) => (
                    <label key={ct} className="type-toggle">
                      <input
                        type="checkbox"
                        checked={s.contentTypes.includes(ct)}
                        onChange={() => toggleType(s, ct)}
                      />
                      {t(TYPE_LABEL[ct])}
                    </label>
                  ))}
                </div>
                {status[s.id] && <IngestStatusLine st={status[s.id]} />}
                <div className="source-refreshed muted">
                  {s.lastRefreshUtc
                    ? t('Last refresh: {when}').replace('{when}', new Date(s.lastRefreshUtc).toLocaleString())
                    : t('Last refresh: never')}
                </div>
                {s.kind === 'xtream' && <SourceExpiry s={s} />}
                <div className="source-actions">
                  <button
                    onClick={() => refreshOne(s.id)}
                    disabled={status[s.id]?.running || busy === `refresh-${s.id}`}
                  >
                    {status[s.id]?.running ? t('Busy…') : t('Refresh')}
                  </button>
                  <button onClick={() => openEdit(s)}>{t('Edit')}</button>
                  <button className="danger" onClick={() => remove(s.id)}>
                    {t('Delete')}
                  </button>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>

      {editorOpen && (
        <Modal
          title={form.id ? t('Edit source #{id}').replace('{id}', String(form.id)) : t('Add source')}
          onClose={() => {
            // while the (nested) filter modal is open, Escape/backdrop closes only that one
            if (!filterModal) closeEditor()
          }}
        >
      <form className="source-form" onSubmit={submit}>
        <label>
          {t('Name')}
          <input
            value={form.name}
            required
            onChange={(e) => setForm({ ...form, name: e.target.value })}
          />
        </label>
        <label>
          {t('Kind')}
          <select
            value={form.kind}
            onChange={(e) => setForm({ ...form, kind: e.target.value as SourceKind })}
          >
            <option value="xtream">xtream</option>
            <option value="m3u">m3u</option>
            {/* MAG/Stalker temporarily removed from the UI until it can be tested
                against a live portal — backend reader is parked, re-add this option
                to bring it back. */}
          </select>
        </label>
        <label>
          {t('URL')}
          <input
            value={form.url}
            required
            placeholder={form.kind === 'stalker' ? t('http://portal/c/ or …/portal.php') : undefined}
            onChange={(e) => setForm({ ...form, url: e.target.value })}
          />
        </label>
        <label>
          {form.kind === 'stalker' ? t('MAC (Username)') : t('Username')}
          <input
            value={form.username}
            placeholder={form.kind === 'stalker' ? '00:1A:79:AA:BB:CC' : undefined}
            title={form.kind === 'stalker' ? t('Stalker/MAG: enter the device MAC address here') : undefined}
            onChange={(e) => setForm({ ...form, username: e.target.value })}
          />
        </label>
        <label>
          {t('Password')}
          <input
            type="password"
            value={form.password}
            onChange={(e) => setForm({ ...form, password: e.target.value })}
          />
        </label>
        <label>
          {t('EPG URL')}
          <input
            value={form.epgUrl}
            onChange={(e) => setForm({ ...form, epgUrl: e.target.value })}
          />
        </label>
        <label>
          {t('User-Agent')}
          <input
            value={form.userAgent}
            placeholder={t('empty = default browser UA')}
            title={t('Some providers block the default UA. E.g. VLC/3.0.20 LibVLC/3.0.20')}
            onChange={(e) => setForm({ ...form, userAgent: e.target.value })}
          />
        </label>
        <label>
          {t('Referer')}
          <input
            value={form.referer}
            placeholder={t('empty = none')}
            title={t('Some portals require a Referer that matches the portal domain, e.g. http://provider.com/c/')}
            onChange={(e) => setForm({ ...form, referer: e.target.value })}
          />
        </label>

        <div className="filter-summary">
          <span className="filter-field-label">
            {form.id
              ? t('Name filters — {name}').replace(
                  '{name}',
                  form.name || t('source #{id}').replace('{id}', String(form.id)),
                )
              : t('Name filters')}
          </span>
          <div className="filter-summary-btns">
            <button type="button" onClick={() => setFilterModal('include')}>
              {t('Include ({n})').replace('{n}', String(form.includeFilters.length))}
            </button>
            <button type="button" onClick={() => setFilterModal('exclude')}>
              {t('Exclude ({n})').replace('{n}', String(form.excludeFilters.length))}
            </button>
            <button
              type="button"
              className="danger"
              onClick={clearFilters}
              disabled={form.includeFilters.length + form.excludeFilters.length === 0}
            >
              {t('Clear filters')}
            </button>
          </div>
          <span className="hint">
            {form.id
              ? t('Tick discovered prefixes or type tokens (prefix OR suffix, case-insensitive). Include = keep only matches (empty = keep all); Exclude = drop matches.')
              : t('Editing an existing source? Click “Edit” on it above first — discovered prefixes come from that source’s channels.')}
          </span>
        </div>

        <label>
          {t('Strip prefixes')}
          <input
            value={form.stripPrefixes}
            placeholder={t('e.g. NL; UK')}
            title={t('Leading tokens removed from a channel name when it is added to a list — e.g. "NL" turns "NL| NPO 1", "|NL|", "NL - …" into the bare name. Separate multiple tokens with ; (a token may contain spaces/commas). Case-insensitive. The name is trimmed afterwards.')}
            onChange={(e) => setForm({ ...form, stripPrefixes: e.target.value })}
          />
        </label>
        <label>
          {t('Strip suffixes')}
          <input
            value={form.stripSuffixes}
            placeholder={t('e.g. (S); rec')}
            title={t('Trailing tokens removed from a channel name when it is added to a list — e.g. "(S)" turns "HISTORY RAW (S)" into "HISTORY RAW". Separate multiple tokens with ;. Case-insensitive; decorative letters (small caps, superscript) match their plain form.')}
            onChange={(e) => setForm({ ...form, stripSuffixes: e.target.value })}
          />
        </label>
        <span className="hint">
          {t('Strip prefixes and suffixes are removed when a channel is added to a list (the catalog keeps the original name).')}
        </span>

        <label className="inline">
          <input
            type="checkbox"
            checked={form.enabled}
            onChange={(e) => setForm({ ...form, enabled: e.target.checked })}
          />
          {t('Enabled')}
        </label>
        <label
          className="inline"
          title={t('Box gets live channels as HLS (.m3u8) even when it asks for .ts. Helps when a provider drops .ts streams every few seconds.')}
        >
          <input
            type="checkbox"
            checked={form.forceHls}
            onChange={(e) => setForm({ ...form, forceHls: e.target.checked })}
          />
          {t('Live always as HLS (m3u8)')}
        </label>
        <label
          className="inline"
          title={t('Use this provider’s own guide for its channels whenever it has data; the extra EPG source (Settings) then only fills gaps. Off: the extra EPG source goes first.')}
        >
          <input
            type="checkbox"
            checked={form.preferOwnEpg}
            onChange={(e) => setForm({ ...form, preferOwnEpg: e.target.checked })}
          />
          {t('Own EPG before the extra EPG source')}
        </label>
        <div className="type-toggles">
          {CONTENT_TYPES.map((ct) => (
            <label key={ct} className="type-toggle">
              <input
                type="checkbox"
                checked={form.contentTypes.includes(ct)}
                onChange={() => formToggleType(ct)}
              />
              {t(TYPE_LABEL[ct])}
            </label>
          ))}
        </div>
        <div className="form-actions">
          <button type="submit" disabled={busy === 'save'}>
            {busy === 'save' ? t('Saving…') : form.id ? t('Save') : t('Add')}
          </button>
          <button type="button" onClick={closeEditor}>
            {t('Cancel')}
          </button>
        </div>
      </form>
        </Modal>
      )}

      {editorOpen && filterModal && (
        <Modal
          title={filterModal === 'include' ? t('Include filters') : t('Exclude filters')}
          onClose={closeFilterModal}
          footer={
            <button type="button" onClick={closeFilterModal}>
              {t('Done')}
            </button>
          }
        >
          <FilterEditor
            kind={filterModal}
            tokens={filterModal === 'include' ? form.includeFilters : form.excludeFilters}
            onChange={filterModal === 'include' ? setInclude : setExclude}
            prefixes={prefixes}
            prefixBusy={prefixBusy}
            editing={form.id != null}
          />
        </Modal>
      )}
    </section>
  )
}

/** Provider subscription end date (Xtream user_info), highlighted when close. */
function SourceExpiry({ s }: { s: Source }) {
  const t = useT()
  const conns = s.maxConnections ? ` · ${t('max {n} connections').replace('{n}', String(s.maxConnections))}` : ''
  if (!s.accountStatus) return <div className="source-expiry muted">{t('Expiry: refresh to fetch')}</div>
  if (!s.expiresUtc)
    return (
      <div className="source-expiry muted">
        {t('No end date')}
        {conns}
      </div>
    )
  const exp = new Date(s.expiresUtc)
  const days = Math.ceil((exp.getTime() - Date.now()) / 86400000)
  const when = exp.toLocaleDateString()
  const cls = days < 0 ? 'source-expiry expired' : days <= 14 ? 'source-expiry soon' : 'source-expiry muted'
  return (
    <div className={cls}>
      {days < 0
        ? t('Expired: {when}').replace('{when}', when)
        : `${t('Expires: {when}').replace('{when}', when)} (${t('in {n} days').replace('{n}', String(days))})`}
      {conns}
    </div>
  )
}

/** One-line ingest progress badge for a source: busy / done / error. */
function IngestStatusLine({ st }: { st: IngestStatus }) {
  const t = useT()
  if (st.running) {
    return (
      <div className="ingest-status running">
        <span className="spinner" /> {t('Ingesting…')}
        {st.streams > 0 && ` ${t('{n} streams').replace('{n}', st.streams.toLocaleString())}`}
      </div>
    )
  }
  if (st.error) {
    return <div className="ingest-status error">{t('⚠ Failed: {error}').replace('{error}', st.error)}</div>
  }
  if (st.finishedUtc) {
    return (
      <div className="ingest-status done">
        {t('✓ Done: {streams} streams').replace('{streams}', st.streams.toLocaleString())}
        {st.categories > 0 && t(', {n} groups').replace('{n}', String(st.categories))}
        {st.programmes > 0 && t(', {n} EPG').replace('{n}', String(st.programmes))}
      </div>
    )
  }
  return null
}

interface FilterEditorProps {
  kind: FilterKind
  tokens: string[]
  onChange: (next: string[]) => void
  prefixes: PrefixCount[]
  prefixBusy: boolean
  editing: boolean
}

/**
 * Roomy include/exclude editor shown in a modal. Tokens can be typed freely (a
 * prefix OR suffix, comma-separated to add several) or ticked from the prefixes
 * discovered in the source's channels. A search box narrows a long prefix list.
 */
export function FilterEditor({ kind, tokens, onChange, prefixes, prefixBusy, editing }: FilterEditorProps) {
  const t = useT()
  const [draft, setDraft] = useState('')
  const [search, setSearch] = useState('')
  const selected = new Set(tokens)

  const visiblePrefixes = useMemo(() => {
    const q = search.trim().toLowerCase()
    if (!q) return prefixes
    return prefixes.filter((p) => p.prefix.toLowerCase().includes(q))
  }, [prefixes, search])

  function add(token: string) {
    const t = token.trim()
    if (t && !selected.has(t)) onChange([...tokens, t])
  }
  function remove(token: string) {
    onChange(tokens.filter((t) => t !== token))
  }
  function toggle(token: string) {
    if (selected.has(token)) remove(token)
    else add(token)
  }
  // add/remove every prefix currently visible (respects the search filter)
  function addAllVisible() {
    const next = [...tokens]
    for (const p of visiblePrefixes) if (!next.includes(p.prefix)) next.push(p.prefix)
    onChange(next)
  }
  function removeAllVisible() {
    const vis = new Set(visiblePrefixes.map((p) => p.prefix))
    onChange(tokens.filter((t) => !vis.has(t)))
  }
  function commitDraft() {
    // a pasted list arrives with line breaks (or ;) — each line is its own token,
    // never one giant item (the backend refuses items over 200 chars)
    draft
      .split(/[,;\r\n]+/)
      .map((t) => t.trim())
      .filter(Boolean)
      .forEach(add)
    setDraft('')
  }

  return (
    <div className="filter-editor">
      <p className="hint">
        {kind === 'include'
          ? t('Keep only channels whose name starts- or ends-with one of these tokens. Leave empty to keep everything.')
          : t('Drop channels whose name starts- or ends-with one of these tokens.')}
      </p>

      <label className="filter-editor-label">
        {t('Selected tokens')}
        {tokens.length > 0 && (
          <button type="button" className="link-btn" onClick={() => onChange([])}>
            {t('clear all')}
          </button>
        )}
      </label>
      {tokens.length > 0 ? (
        <div className="chips">
          {tokens.map((tok) => (
            <span key={tok} className="chip">
              {tok}
              <button type="button" className="chip-x" title={t('Remove')} onClick={() => remove(tok)}>
                ×
              </button>
            </span>
          ))}
        </div>
      ) : (
        <p className="muted">{t('None yet.')}</p>
      )}

      <div className="filter-add">
        <input
          autoFocus
          value={draft}
          placeholder={kind === 'include' ? t('e.g. NL|, UK:') : t('e.g. XXX, ADULT')}
          onChange={(e) => setDraft(e.target.value)}
          onPaste={(e) => {
            // an <input> silently drops line breaks, gluing a pasted multi-line
            // list into ONE huge token — split it here and add each line instead
            const text = e.clipboardData.getData('text')
            if (!/[\r\n]/.test(text)) return
            e.preventDefault()
            text
              .split(/[,;\r\n]+/)
              .map((t) => t.trim())
              .filter(Boolean)
              .forEach(add)
          }}
          onKeyDown={(e) => {
            if (e.key === 'Enter') {
              e.preventDefault()
              commitDraft()
            }
          }}
        />
        <button type="button" onClick={commitDraft} disabled={!draft.trim()}>
          {t('Add')}
        </button>
      </div>

      <label className="filter-editor-label">
        {t('Discovered prefixes')}
        {editing && !prefixBusy && prefixes.length > 0 && (
          <span className="filter-editor-actions">
            <button type="button" className="link-btn" onClick={addAllVisible}>
              {search.trim() ? t('select all shown') : t('select all')}
            </button>
            <button type="button" className="link-btn" onClick={removeAllVisible}>
              {t('none')}
            </button>
          </span>
        )}
      </label>
      {!editing ? (
        <span className="hint">{t('Save the source and refresh it to discover prefixes.')}</span>
      ) : prefixBusy ? (
        <span className="hint">{t('Discovering prefixes…')}</span>
      ) : prefixes.length === 0 ? (
        <span className="hint">{t('No prefixes found — refresh the source to discover them.')}</span>
      ) : (
        <>
          <input
            className="prefix-search"
            placeholder={t('Search {n} prefixes…').replace('{n}', String(prefixes.length))}
            value={search}
            onChange={(e) => setSearch(e.target.value)}
          />
          <div className="prefix-picker roomy">
            {visiblePrefixes.map((p) => (
              <label
                key={p.prefix}
                className={selected.has(p.prefix) ? 'prefix-chip on' : 'prefix-chip'}
                title={t('{n} channels').replace('{n}', String(p.count))}
              >
                <input
                  type="checkbox"
                  checked={selected.has(p.prefix)}
                  onChange={() => toggle(p.prefix)}
                />
                {p.prefix} <span className="muted">{p.count}</span>
              </label>
            ))}
            {visiblePrefixes.length === 0 && <span className="hint">{t('No match.')}</span>}
          </div>
        </>
      )}
    </div>
  )
}
