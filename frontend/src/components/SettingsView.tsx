import { useEffect, useState, type ChangeEvent, type FormEvent } from 'react'
import { api, type SettingsBundle } from '../api/client'
import type { AppConfig, CustomList, MirrorCredential, Source } from '../types'
import { isMirror } from '../lib/mirror'
import { useI18n, useT } from '../i18n'

// valid TCP port range for the relay (proxy) port
const PORT_MIN = 1
const PORT_MAX = 65535
// EPG retention: input range and the shown default when unset
const EPG_MAX_DAYS = { min: 0, max: 366, def: 7 } // backend cMaxEpgMaxDays

interface Props {
  lists: CustomList[]
  /** Refresh the app-level lists after a create/edit/delete. */
  onListsChanged: () => void
  /** after a settings import (sources + lists changed) */
  onImported?: () => void
}

/**
 * Admin screen: service settings (daily refresh time, stream-proxy toggle) and
 * output-list management (name + optional output credentials + enabled). Lists
 * are what an IPTV box authenticates as; an empty username = the default list.
 */
export function SettingsView({ lists, onListsChanged, onImported }: Props) {
  // bumped after an import: the import replaces config + lists server-side, so
  // the service form re-fetches its config and the list editors drop any
  // pre-import local state (a later Save would otherwise overwrite the import)
  const [importEpoch, setImportEpoch] = useState(0)
  return (
    <div className="settings-view">
      <LanguagePicker />
      <ServiceSettings key={`svc-${importEpoch}`} />
      <ListManager key={`lists-${importEpoch}`} lists={lists} onChanged={onListsChanged} />
      <SettingsIO
        onChanged={() => {
          setImportEpoch((n) => n + 1)
          ;(onImported ?? onListsChanged)()
        }}
      />
    </div>
  )
}

/** UI-language picker. Uses useI18n() (which has a safe no-provider default), so
 *  it renders fine in tests without an <I18nProvider>. */
function LanguagePicker() {
  const t = useT()
  const { locale, setLocale, languages } = useI18n()
  return (
    <section className="panel settings-card">
      <header className="panel-head">
        <h2>{t('Language')}</h2>
      </header>
      <div className="panel-body">
        <label className="inline">
          {t('Language')}
          <select
            aria-label={t('Language')}
            value={locale}
            onChange={(e) => setLocale(e.target.value)}
          >
            {languages.map((l) => (
              <option key={l.code} value={l.code}>
                {l.name}
              </option>
            ))}
          </select>
        </label>
      </div>
    </section>
  )
}

/**
 * Export / import the whole settings bundle (config + sources + lists + groups)
 * as one JSON file, so a setup can be cloned to another instance. Import REPLACES
 * everything (and clears the catalog); the picked channels are not included.
 */
function SettingsIO({ onChanged }: { onChanged: () => void }) {
  const t = useT()
  const [error, setError] = useState<string | null>(null)
  const [msg, setMsg] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [pending, setPending] = useState<{ bundle: SettingsBundle; name: string } | null>(null)

  async function doExport() {
    setError(null); setMsg(null); setBusy(true)
    try {
      const bundle = await api.exportSettings()
      const blob = new Blob([JSON.stringify(bundle, null, 2)], { type: 'application/json' })
      const url = URL.createObjectURL(blob)
      const a = document.createElement('a')
      a.href = url
      a.download = 'iptv-settings.json'
      a.click()
      URL.revokeObjectURL(url)
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function pickFile(e: ChangeEvent<HTMLInputElement>) {
    setError(null); setMsg(null)
    const file = e.target.files?.[0]
    e.target.value = '' // allow re-picking the same file
    if (!file) return
    try {
      const bundle = JSON.parse(await file.text()) as SettingsBundle
      if (!bundle || (!bundle.sources && !bundle.lists)) {
        setError(t('Not a valid settings file.'))
        return
      }
      setPending({ bundle, name: file.name })
    } catch {
      setError(t('Not a valid JSON file.'))
    }
  }

  async function confirmImport() {
    if (!pending) return
    setBusy(true); setError(null)
    try {
      const r = await api.importSettings(pending.bundle)
      setMsg(
        t('Imported: {sources} sources, {lists} lists, {groups} groups. Refresh the sources to populate the catalog.')
          .replace('{sources}', String(r.sources))
          .replace('{lists}', String(r.lists))
          .replace('{groups}', String(r.groups)),
      )
      setPending(null)
      onChanged()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="panel settings-card">
      <header className="panel-head">
        <h2>{t('Settings export / import')}</h2>
      </header>
      {error && <p className="error">{error}</p>}
      {msg && <p className="muted">{msg}</p>}
      <div className="panel-body settings-io">
        <div className="form-actions">
          <button type="button" onClick={doExport} disabled={busy}>
            {t('Export to file')}
          </button>
          <label className="file-btn">
            {t('Choose import file…')}
            <input type="file" accept="application/json,.json" onChange={pickFile} hidden />
          </label>
        </div>
        {pending && (
          <div className="import-confirm">
            <span>
              <strong>{pending.name}</strong> — {pending.bundle.sources?.length ?? 0}{' '}
              {t('sources')},{' '}
              {pending.bundle.lists?.length ?? 0} {t('lists')}.{' '}
              {t('This replaces all current sources + lists (and clears the catalog).')}
            </span>
            <div className="form-actions">
              <button type="button" className="danger" onClick={confirmImport} disabled={busy}>
                {busy ? t('Importing…') : t('Replace everything')}
              </button>
              <button type="button" onClick={() => setPending(null)} disabled={busy}>
                {t('Cancel')}
              </button>
            </div>
          </div>
        )}
        <span className="hint">
          {t('Contains settings + sources + lists + groups — not the chosen channels. Importing replaces the entire configuration; refresh the sources afterwards.')}
        </span>
      </div>
    </section>
  )
}

/** The keys of `form` whose value differs from `orig` (all of them when there is no orig). */
export function changedFields<T extends object>(form: Partial<T>, orig: T | null): Partial<T> {
  if (!orig) return form
  const out: Partial<T> = {}
  for (const k of Object.keys(form) as (keyof T)[]) {
    if (JSON.stringify(form[k]) !== JSON.stringify((orig as T)[k])) out[k] = form[k]
  }
  return out
}

function ServiceSettings() {
  const t = useT()
  const [cfg, setCfg] = useState<AppConfig | null>(null)
  // what the server had when the form was loaded/saved: only fields the user
  // actually changed are sent, so this form can't undo a change made elsewhere
  // meanwhile (e.g. the proxy toggled from the header)
  const [orig, setOrig] = useState<AppConfig | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [busy, setBusy] = useState(false)
  // proxy port as typed: may be empty/partial while editing; clamped on blur/save
  const [portText, setPortText] = useState<string | null>(null)

  useEffect(() => {
    api
      .getConfig()
      .then((c) => {
        setCfg(c)
        setOrig(c)
      })
      .catch((e) => setError((e as Error).message))
  }, [])

  function patch(p: Partial<AppConfig>) {
    setCfg((c) => (c ? { ...c, ...p } : c))
    setSaved(false)
  }

  async function save(e: FormEvent) {
    e.preventDefault()
    if (!cfg) return
    // the port field may still hold an in-progress value: validate it now
    let proxyPort = cfg.proxyPort
    if (portText != null) {
      if (portText.trim() !== '') proxyPort = clamp(portText, PORT_MIN, PORT_MAX)
      setPortText(null)
      patch({ proxyPort })
    }
    setBusy(true)
    setError(null)
    try {
      const form: Partial<AppConfig> = {
        refreshHour: cfg.refreshHour,
        refreshMinute: cfg.refreshMinute,
        epgMaxDays: cfg.epgMaxDays,
        proxyStreams: cfg.proxyStreams,
        proxyPort,
        streamFailover: cfg.streamFailover,
        extraEpgUrls: (cfg.extraEpgUrls ?? []).map((u) => u.trim()).filter(Boolean),
        mediaAllowedClients: (cfg.mediaAllowedClients ?? []).map((u) => u.trim()).filter(Boolean),
      }
      // a missing list and an empty list are the same setting
      const changed = changedFields(
        form,
        orig && {
          ...orig,
          extraEpgUrls: orig.extraEpgUrls ?? [],
          mediaAllowedClients: orig.mediaAllowedClients ?? [],
        },
      )
      const next = await api.saveConfig(changed)
      setCfg(next)
      setOrig(next)
      setSaved(true)
    } catch (err) {
      setError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  return (
    <section className="panel settings-card">
      <header className="panel-head">
        <h2>{t('Service settings')}</h2>
      </header>
      {error && <p className="error">{error}</p>}
      {!cfg ? (
        <div className="panel-body">
          <p className="muted">{t('Loading…')}</p>
        </div>
      ) : (
        <form className="settings-form" onSubmit={save}>
          <fieldset>
            <legend>{t('Daily refresh')}</legend>
            <label className="inline">
              {t('Time')}
              <input
                type="number"
                min={0}
                max={23}
                value={cfg.refreshHour}
                onChange={(e) => patch({ refreshHour: clamp(e.target.value, 0, 23) })}
              />
              :
              <input
                type="number"
                min={0}
                max={59}
                value={cfg.refreshMinute}
                onChange={(e) => patch({ refreshMinute: clamp(e.target.value, 0, 59) })}
              />
            </label>
            <span className="hint">{t('Local time the service refreshes all sources + EPG.')}</span>
            <label className="inline">
              {t('EPG max days')}
              <input
                type="number"
                min={EPG_MAX_DAYS.min}
                max={EPG_MAX_DAYS.max}
                value={cfg.epgMaxDays ?? EPG_MAX_DAYS.def}
                onChange={(e) => patch({ epgMaxDays: clamp(e.target.value, EPG_MAX_DAYS.min, EPG_MAX_DAYS.max) })}
              />
            </label>
            <span className="hint">
              {t('Limit the generated guide to this many days ahead (0 = unlimited, takes everything the providers supply).')}
            </span>
          </fieldset>

          <fieldset>
            <legend>{t('Extra EPG sources')}</legend>
            <textarea
              className="extra-epg"
              rows={3}
              placeholder="https://…/guide.xml.gz"
              value={(cfg.extraEpgUrls ?? []).join('\n')}
              onChange={(e) => patch({ extraEpgUrls: e.target.value.split('\n') })}
            />
            <span className="hint">
              {t('One XMLTV address per line (.xml or .xml.gz), e.g. a country guide. Channels are matched by name or tvg-id and get these programmes instead of the provider’s own guide, unless that source has “Own EPG before the extra EPG source”. Channel ids and numbers stay the same. Fetched with every refresh or “Update EPG”. The first line wins when guides overlap.')}
            </span>
          </fieldset>

          <fieldset>
            <legend>{t('Media servers: allowed clients')}</legend>
            <textarea
              className="extra-epg"
              rows={2}
              placeholder="192.168.1.20"
              value={(cfg.mediaAllowedClients ?? []).join('\n')}
              onChange={(e) => patch({ mediaAllowedClients: e.target.value.split('\n') })}
            />
            <span className="hint">
              {t('The Plex/Jellyfin tuner and HDHomeRun addresses have no login. One IP address per line (e.g. your Plex server), or a prefix ending in a dot such as 192.168.1. for a whole network. Empty = every client.')}
            </span>
          </fieldset>

          <fieldset>
            <legend>{t('Stream proxy')}</legend>
            <label className="inline">
              <input
                type="checkbox"
                checked={cfg.proxyStreams}
                onChange={(e) => patch({ proxyStreams: e.target.checked })}
              />
              {t('Relay streams through this server')}
            </label>
            <label className="inline">
              {t('Proxy port')}
              <input
                type="number"
                min={PORT_MIN}
                max={PORT_MAX}
                value={portText ?? String(cfg.proxyPort)}
                disabled={!cfg.proxyStreams}
                onChange={(e) => {
                  // keep the raw text so the field can be cleared and retyped;
                  // only a non-empty value updates the setting
                  setPortText(e.target.value)
                  if (e.target.value.trim() !== '') patch({ proxyPort: clamp(e.target.value, PORT_MIN, PORT_MAX) })
                }}
                onBlur={() => setPortText(null)}
              />
            </label>
            <span className="hint">
              {t('OFF (default): the box gets the raw provider URL — video never flows through us. ON: output URLs point back here and we relay the bytes (handy abroad; costs bandwidth/CPU). Applied live.')}
            </span>
            <label className="inline">
              <input
                type="checkbox"
                checked={!!cfg.streamFailover}
                disabled={!cfg.proxyStreams}
                onChange={(e) => patch({ streamFailover: e.target.checked })}
              />
              {t('Fail over to another source when a channel is down')}
            </label>
            <span className="hint">
              {t('Only while relaying: if a channel’s provider can’t be reached, try the same channel (matched by tvg-id, else exact name) from another source. A plain 302 redirect can’t fail over.')}
            </span>
          </fieldset>

          <span className="hint">
            {t('Plex/Jellyfin tuners, the channel filter and dummy EPG live in the “Media Servers” tab.')}
          </span>

          <div className="form-actions">
            <button type="submit" disabled={busy}>
              {busy ? t('Saving…') : t('Save settings')}
            </button>
            {saved && <span className="muted">{t('Saved ✓')}</span>}
          </div>
        </form>
      )}
    </section>
  )
}

function clamp(v: string, lo: number, hi: number): number {
  const n = Number(v)
  if (Number.isNaN(n)) return lo
  return Math.min(hi, Math.max(lo, Math.trunc(n)))
}

interface ListManagerProps {
  lists: CustomList[]
  onChanged: () => void
}

/** Sentinel value of the picker that means "create a new list". */
const NEW_LIST = 'new'

function ListManager({ lists, onChanged }: ListManagerProps) {
  const t = useT()
  const [error, setError] = useState<string | null>(null)
  // Which list the picker has focused: a list id, or NEW_LIST for the add form.
  const [selected, setSelected] = useState<number | typeof NEW_LIST>(
    lists[0]?.id ?? NEW_LIST,
  )

  // Keep the selection valid as lists change (e.g. after a create/delete):
  // a freshly added list isn't in `lists` until onChanged refreshes it, so if
  // the current selection vanished, fall back to the first list (or the add form).
  useEffect(() => {
    if (selected === NEW_LIST) return
    if (!lists.some((l) => l.id === selected)) {
      setSelected(lists[0]?.id ?? NEW_LIST)
    }
  }, [lists, selected])

  const current = selected === NEW_LIST ? null : lists.find((l) => l.id === selected) ?? null

  // A mirror's own provider accounts are stored separately, AFTER the list: the
  // backend only accepts them once the list is (saved as) a mirror.
  async function saveExisting(
    patch: Partial<CustomList> & { id: number },
    credentials?: MirrorCredential[],
  ) {
    setError(null)
    try {
      await api.saveList(patch)
    } catch (err) {
      setError((err as Error).message)
      return
    }
    try {
      if (credentials) await api.saveMirrorCredentials(patch.id, credentials)
    } catch (err) {
      setError((err as Error).message)
    }
    onChanged()
  }

  async function createList(draft: Partial<CustomList>, credentials?: MirrorCredential[]) {
    setError(null)
    let saved: CustomList | undefined
    try {
      saved = await api.saveList({
        name: draft.name!.trim(),
        outputUsername: draft.outputUsername?.trim() ?? '',
        outputPassword: draft.outputPassword?.trim() ?? '',
        enabled: draft.enabled ?? true,
        mirrorOfListId: draft.mirrorOfListId ?? 0,
      })
    } catch (err) {
      setError((err as Error).message)
      throw err // the editor keeps the typed values on failure
    }
    try {
      if (credentials && saved?.id) await api.saveMirrorCredentials(saved.id, credentials)
    } catch (err) {
      // the list exists now; only its accounts failed - edit it to retry
      setError((err as Error).message)
    }
    onChanged()
  }

  async function remove(l: CustomList) {
    setError(null)
    try {
      await api.deleteList(l.id)
      onChanged()
    } catch (err) {
      setError((err as Error).message)
    }
  }

  return (
    <section className="panel settings-card">
      <header className="panel-head">
        <h2>{t('Output lists')}</h2>
      </header>
      {error && <p className="error">{error}</p>}
      <div className="panel-body">
        <label className="inline list-picker">
          {t('List')}
          <select
            aria-label="Select list"
            value={selected === NEW_LIST ? NEW_LIST : String(selected)}
            onChange={(e) =>
              setSelected(e.target.value === NEW_LIST ? NEW_LIST : Number(e.target.value))
            }
          >
            {lists.map((l) => (
              <option key={l.id} value={String(l.id)}>
                {(l.name || t('(unnamed)')) +
                  (l.outputUsername ? '' : t(' — default')) +
                  (l.enabled ? '' : t(' (disabled)'))}
              </option>
            ))}
            <option value={NEW_LIST}>{t('➕ New list…')}</option>
          </select>
        </label>

        {current ? (
          <ListEditor
            // keyed on the server values too: when the list changes underneath
            // (e.g. a settings import), the editor restarts from the new values
            key={JSON.stringify([current.id, current.name, current.outputUsername, current.outputPassword, current.enabled, current.mirrorOfListId ?? 0])}
            list={current}
            lists={lists}
            onSave={saveExisting}
            onDelete={(l) => {
              remove(l)
              setSelected(NEW_LIST)
            }}
          />
        ) : (
          <ListEditor key="new" lists={lists} onCreate={createList} onCreated={() => undefined} />
        )}

        <span className="hint">
          {t('Credentials are optional: a list with an empty username becomes the default the box resolves to when it sends no/unknown login.')}
        </span>
      </div>
    </section>
  )
}

interface ListEditorProps {
  /** Existing list to edit; omit for the "new list" form. */
  list?: CustomList
  /** Every list (the "Mirror of" choices). */
  lists: CustomList[]
  onSave?: (patch: Partial<CustomList> & { id: number }, credentials?: MirrorCredential[]) => void
  onDelete?: (l: CustomList) => void
  onCreate?: (draft: Partial<CustomList>, credentials?: MirrorCredential[]) => Promise<void>
  onCreated?: () => void
}

/** A mirror's per-source account as edited in the form ('' = the source's own value). */
type CredForm = Record<number, { url: string; username: string; password: string }>
const EMPTY_CRED = { url: '', username: '', password: '' }

/** The rows worth storing: trimmed, and only sources with at least one value. */
function credentialsToSave(sources: Source[], creds: CredForm): MirrorCredential[] {
  const out: MirrorCredential[] = []
  for (const src of sources) {
    const c = creds[src.id] ?? EMPTY_CRED
    const row = {
      sourceId: src.id,
      url: c.url.trim(),
      username: c.username.trim(),
      password: c.password.trim(),
    }
    if (row.url || row.username || row.password) out.push(row)
  }
  return out
}

/**
 * Edits a single output list (or, with no `list`, captures a new one). Same set
 * of fields either way — the picker decides which list this is bound to.
 */
function ListEditor({ list, lists, onSave, onDelete, onCreate, onCreated }: ListEditorProps) {
  const t = useT()
  const [name, setName] = useState(list?.name ?? '')
  const [username, setUsername] = useState(list?.outputUsername ?? '')
  const [password, setPassword] = useState(list?.outputPassword ?? '')
  const [enabled, setEnabled] = useState(list?.enabled ?? true)
  const [mirrorOf, setMirrorOf] = useState(list?.mirrorOfListId ?? 0)
  const [sources, setSources] = useState<Source[] | null>(null)
  const [creds, setCreds] = useState<CredForm>({})
  const [credsDirty, setCredsDirty] = useState(false)
  const [confirming, setConfirming] = useState(false)
  const [busy, setBusy] = useState(false)

  // one level only: a mirror can't be mirrored, and a list can't mirror itself
  const masters = lists.filter((l) => !isMirror(l) && l.id !== list?.id)
  // a list that other bouquets mirror can't become a mirror itself
  const mirroredBy = list ? lists.filter((l) => l.mirrorOfListId === list.id) : []
  const mirroring = mirrorOf > 0

  // the per-source account table needs the sources: fetched once a mirror is picked
  useEffect(() => {
    if (!mirroring || sources) return
    let cancelled = false
    api
      .listSources()
      .then((s) => {
        if (!cancelled) setSources(s)
      })
      .catch(() => {
        if (!cancelled) setSources([])
      })
    return () => {
      cancelled = true
    }
  }, [mirroring, sources])

  // the stored accounts of an existing mirror
  const listId = list?.id
  const storedMirror = isMirror(list)
  useEffect(() => {
    if (listId == null || !storedMirror) return
    let cancelled = false
    api
      .getMirrorCredentials(listId)
      .then((rows) => {
        if (cancelled) return
        const next: CredForm = {}
        for (const r of rows ?? [])
          next[r.sourceId] = { url: r.url ?? '', username: r.username ?? '', password: r.password ?? '' }
        setCreds(next)
      })
      .catch(() => {})
    return () => {
      cancelled = true
    }
  }, [listId, storedMirror])

  function setCred(sourceId: number, field: keyof typeof EMPTY_CRED, value: string) {
    setCreds((prev) => ({ ...prev, [sourceId]: { ...(prev[sourceId] ?? EMPTY_CRED), [field]: value } }))
    setCredsDirty(true)
  }

  const dirty =
    !list ||
    name !== list.name ||
    username !== list.outputUsername ||
    password !== list.outputPassword ||
    enabled !== list.enabled ||
    mirrorOf !== (list.mirrorOfListId ?? 0) ||
    (mirroring && credsDirty)

  async function submit(e: FormEvent) {
    e.preventDefault()
    if (!name.trim()) return
    // only a mirror has accounts of its own (the backend refuses them otherwise)
    const credentials = mirroring ? credentialsToSave(sources ?? [], creds) : undefined
    if (list) {
      onSave?.(
        {
          id: list.id,
          name: name.trim(),
          outputUsername: username.trim(),
          outputPassword: password.trim(),
          enabled,
          mirrorOfListId: mirrorOf,
        },
        credentials,
      )
      return
    }
    setBusy(true)
    try {
      await onCreate?.(
        { name, outputUsername: username, outputPassword: password, enabled, mirrorOfListId: mirrorOf },
        credentials,
      )
      setName('')
      setUsername('')
      setPassword('')
      setEnabled(true)
      setMirrorOf(0)
      setCreds({})
      setCredsDirty(false)
      onCreated?.()
    } catch {
      // the parent shows the error; keep the form values for a retry
    } finally {
      setBusy(false)
    }
  }

  return (
    <form className="list-edit" onSubmit={submit}>
      <div className="list-edit-grid">
        <label>
          {t('Name')}
          <input value={name} onChange={(e) => setName(e.target.value)} required />
        </label>
        <label>
          {t('Username (optional)')}
          <input value={username} onChange={(e) => setUsername(e.target.value)} />
        </label>
        <label>
          {t('Password (optional)')}
          <input value={password} onChange={(e) => setPassword(e.target.value)} />
        </label>
        <label className="inline">
          <input
            type="checkbox"
            checked={enabled}
            onChange={(e) => setEnabled(e.target.checked)}
          />
          {t('Enabled')}
        </label>
      </div>

      <label className="inline list-mirror-of">
        {t('Mirror of')}
        <select
          value={String(mirrorOf)}
          disabled={mirroredBy.length > 0 && !mirroring}
          onChange={(e) => setMirrorOf(Number(e.target.value))}
        >
          <option value="0">{t('(none — own channels)')}</option>
          {masters.map((l) => (
            <option key={l.id} value={String(l.id)}>
              {l.name || t('(unnamed)')}
            </option>
          ))}
        </select>
      </label>
      <span className="hint">
        {mirroredBy.length > 0 && !mirroring
          ? t('Mirrored by {names}, so this bouquet can’t mirror another one itself.').replace(
              '{names}',
              mirroredBy.map((l) => `“${l.name}”`).join(', '),
            )
          : t('A mirror always shows the channels of the chosen bouquet (read-only) and plays them with its own provider account.')}
      </span>

      {mirroring && (
        <div className="mirror-creds">
          {sources == null ? (
            <p className="muted">{t('Loading…')}</p>
          ) : sources.length === 0 ? (
            <p className="muted">{t('No sources yet.')}</p>
          ) : (
            <div className="table-wrap">
              <table className="data-table mirror-creds-table">
                <thead>
                  <tr>
                    <th>{t('Source')}</th>
                    <th>{t('Server URL')}</th>
                    <th>{t('Username')}</th>
                    <th>{t('Password')}</th>
                  </tr>
                </thead>
                <tbody>
                  {sources.map((src) => {
                    const c = creds[src.id] ?? EMPTY_CRED
                    return (
                      <tr key={src.id}>
                        <td>{src.name}</td>
                        <td>
                          <input
                            aria-label={t('Server URL for {source}').replace('{source}', src.name)}
                            placeholder={t('(same as the source)')}
                            value={c.url}
                            onChange={(e) => setCred(src.id, 'url', e.target.value)}
                          />
                        </td>
                        <td>
                          <input
                            aria-label={t('Username for {source}').replace('{source}', src.name)}
                            placeholder={t('(same as the source)')}
                            value={c.username}
                            onChange={(e) => setCred(src.id, 'username', e.target.value)}
                          />
                        </td>
                        <td>
                          <input
                            aria-label={t('Password for {source}').replace('{source}', src.name)}
                            placeholder={t('(same as the source)')}
                            value={c.password}
                            onChange={(e) => setCred(src.id, 'password', e.target.value)}
                          />
                        </td>
                      </tr>
                    )
                  })}
                </tbody>
              </table>
            </div>
          )}
          <span className="hint">
            {t('Only for another account at the same provider; the server URL must point to that same provider.')}
          </span>
        </div>
      )}

      <div className="form-actions">
        <button type="submit" disabled={busy || !name.trim() || !dirty}>
          {list ? t('Save') : busy ? t('Adding…') : t('Add list')}
        </button>
        {list &&
          (confirming ? (
            <>
              <button type="button" className="danger" onClick={() => onDelete?.(list)}>
                {t('Confirm delete')}
              </button>
              <button type="button" onClick={() => setConfirming(false)}>
                {t('Cancel')}
              </button>
            </>
          ) : (
            <button type="button" className="danger" onClick={() => setConfirming(true)}>
              {t('Delete')}
            </button>
          ))}
      </div>
    </form>
  )
}
