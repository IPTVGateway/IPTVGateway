import { useEffect, useMemo, useState } from 'react'
import { api, type CatalogQuery } from '../api/client'
import type {
  Category,
  ContentType,
  CustomGroup,
  CustomList,
  Source,
  StreamItem,
} from '../types'
import { SEARCH_DEBOUNCE_MS, useDebounced } from '../hooks/useDebounced'
import { CONTENT_LIVE, CONTENT_TYPES, byNameCI, compareGroups } from '../lib/ordering'
import { useT } from '../i18n'
import { QualityProbeModal } from './QualityProbeModal'
import { ArchiveBadge } from './ArchiveBadge'

interface Props {
  sources: Source[]
  lists: CustomList[]
  /** Groups for the currently active list, used as "add to group" targets. */
  groups: CustomGroup[]
  activeListId: number | null
  /** Called after items were added to a list so the curated panel can refresh. */
  onItemsAdded?: () => void
}

const PAGE_SIZES = [50, 100, 200] as const
const DEFAULT_PAGE_SIZE = 100

export function CatalogPanel({ sources, lists, groups, activeListId, onItemsAdded }: Props) {
  const t = useT()
  // --- filter bar -----------------------------------------------------------
  const [search, setSearch] = useState('')
  const [prefix, setPrefix] = useState('')
  const [type, setType] = useState<ContentType>(CONTENT_LIVE)
  const [sourceId, setSourceId] = useState<number | ''>('')
  const [onlyNew, setOnlyNew] = useState(false)

  const debSearch = useDebounced(search, SEARCH_DEBOUNCE_MS)
  const debPrefix = useDebounced(prefix, SEARCH_DEBOUNCE_MS)
  const searchTerm = debSearch.trim()
  const prefixTerm = debPrefix.trim()

  // --- navigation: groups view vs. drilled stream view ----------------------
  const [drill, setDrill] = useState<Category | null>(null)

  // --- paging ---------------------------------------------------------------
  const [pageSize, setPageSize] = useState<number>(DEFAULT_PAGE_SIZE)
  const [page, setPage] = useState(0) // zero-based

  // --- data -----------------------------------------------------------------
  const [categories, setCategories] = useState<Category[]>([])
  const [streams, setStreams] = useState<StreamItem[]>([])
  const [total, setTotal] = useState(0)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [selected, setSelected] = useState<Set<number>>(new Set())
  const [catReload, setCatReload] = useState(0) // bump to re-fetch the group list
  const [streamReload, setStreamReload] = useState(0) // bump to re-fetch the stream page
  const [probe, setProbe] = useState<StreamItem | null>(null) // "measure quality" dialog
  // Note: there is intentionally no client-side "show unfiltered" switch — the
  // backend always applies each source's include/exclude filters, so only the
  // filtered rows ever cross the wire. Manage filters in the source editor.

  // Target for "Add selected to list".
  const [targetListId, setTargetListId] = useState<number | ''>(activeListId ?? '')
  const [targetGroupId, setTargetGroupId] = useState<number>(0)
  const [busy, setBusy] = useState<string | null>(null)

  useEffect(() => {
    if (activeListId != null) setTargetListId(activeListId)
    // the active list (and thus its groups) changed → drop any group id picked
    // for the previous list, so we never assign a foreign group to added items
    setTargetGroupId(0)
  }, [activeListId])

  // The custom-group dropdown lists the ACTIVE list's groups. If you target a
  // different list, those group ids don't belong to it — so only "Upstream group"
  // is valid there (prevents assigning a foreign group id to the items).
  const groupForActiveList = targetListId === activeListId
  useEffect(() => {
    if (!groupForActiveList) setTargetGroupId(0)
  }, [groupForActiveList])

  const sourceName = useMemo(() => {
    const m = new Map<number, string>()
    for (const s of sources) m.set(s.id, s.name)
    return m
  }, [sources])

  // A source must be picked to drill into groups; a flat search still works
  // across "All sources".
  const hasSource = sourceId !== ''
  // Show a flat (no-group) paged stream list only when searching with no group.
  const flatSearch = !drill && searchTerm.length > 0

  // Reset drill / paging / selection when the core filters change.
  useEffect(() => {
    setDrill(null)
    setPage(0)
    setSelected(new Set())
  }, [sourceId, type, onlyNew])

  // Reset to first page whenever the result set could change.
  useEffect(() => {
    setPage(0)
  }, [drill, searchTerm, prefixTerm, pageSize, flatSearch])

  // --- load GROUPS (default view, when not drilled and not flat-searching) --
  useEffect(() => {
    if (drill || flatSearch) return
    let cancelled = false
    setLoading(true)
    setError(null)
    const q: CatalogQuery = {
      sourceId: sourceId === '' ? undefined : sourceId,
      type,
      onlyNew: onlyNew || undefined,
      search: searchTerm || undefined,
    }
    api
      .categories(q)
      .then((rows) => {
        if (!cancelled) setCategories(rows)
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
    // `sources` is in the deps so editing a source's filters (which bumps the
    // sources list) re-applies the live filter to the catalog immediately.
  }, [drill, flatSearch, sourceId, type, onlyNew, searchTerm, catReload, sources])

  // --- load STREAMS (paged) for the drilled group or a flat search ----------
  const streamQuery: CatalogQuery | null = useMemo(() => {
    if (!drill && !flatSearch) return null
    return {
      // a drilled group belongs to ONE source and type (upstream ids repeat across
      // sources, so with "All sources" the group's own source must be sent)
      sourceId: drill ? drill.sourceId : sourceId === '' ? undefined : sourceId,
      type: drill ? drill.contentType : type,
      onlyNew: onlyNew || undefined,
      search: searchTerm || undefined,
      prefix: prefixTerm || undefined,
      category: drill ? drill.upstreamId : undefined,
      inCategory: drill ? true : undefined, // also for a group with an empty id
    }
  }, [drill, flatSearch, sourceId, type, onlyNew, searchTerm, prefixTerm])

  useEffect(() => {
    if (!streamQuery) {
      setStreams([])
      setTotal(0)
      return
    }
    let cancelled = false
    setLoading(true)
    setError(null)
    const paged: CatalogQuery = { ...streamQuery, limit: pageSize, offset: page * pageSize }
    Promise.all([api.streams(paged), api.countStreams(streamQuery)])
      .then(([rows, c]) => {
        if (cancelled) return
        setStreams(rows)
        setTotal(c.count)
        // Drop selections no longer on the current page.
        setSelected((prev) => {
          const visible = new Set(rows.map((r) => r.id))
          const next = new Set<number>()
          for (const id of prev) if (visible.has(id)) next.add(id)
          return next
        })
      })
      .catch((e) => {
        if (!cancelled) setError((e as Error).message)
      })
      .finally(() => {
        if (!cancelled) setLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [streamQuery, pageSize, page, sources, streamReload])

  const pageCount = Math.max(1, Math.ceil(total / pageSize))
  const showingStreams = drill != null || flatSearch

  const sortedCategories = useMemo(
    () => [...categories].sort((a, b) => byNameCI(a.name, b.name)),
    [categories],
  )
  const sortedGroups = useMemo(() => [...groups].sort(compareGroups), [groups])

  const allVisibleSelected = streams.length > 0 && streams.every((s) => selected.has(s.id))

  // Human-readable description of where "Add selected" will put the channels.
  const targetListName = lists.find((l) => l.id === targetListId)?.name
  const targetGroup = sortedGroups.find((g) => g.id === targetGroupId)
  const targetGroupLabel = targetGroupId === 0 ? t('Upstream group') : (targetGroup?.name ?? '—')

  function toggleOne(id: number) {
    setSelected((prev) => {
      const next = new Set(prev)
      if (next.has(id)) next.delete(id)
      else next.add(id)
      return next
    })
  }

  function toggleAll() {
    setSelected((prev) => {
      if (streams.length > 0 && streams.every((s) => prev.has(s.id))) return new Set()
      return new Set(streams.map((s) => s.id))
    })
  }

  function openGroup(c: Category) {
    setDrill(c)
    setPage(0)
    setSelected(new Set())
  }

  async function markGroupSeen(c: Category) {
    setError(null)
    try {
      await api.markCategoriesSeen([c.id])
      setCatReload((n) => n + 1) // clears the NEW badge
    } catch (e) {
      setError((e as Error).message)
    }
  }

  const newCategoryCount = useMemo(
    () => sortedCategories.filter((c) => c.isNew).length,
    [sortedCategories],
  )

  async function markAllGroupsSeen() {
    const ids = sortedCategories.filter((c) => c.isNew).map((c) => c.id)
    if (ids.length === 0) return
    setError(null)
    try {
      await api.markCategoriesSeen(ids)
      setCatReload((n) => n + 1)
    } catch (e) {
      setError((e as Error).message)
    }
  }

  function backToGroups() {
    setDrill(null)
    setPage(0)
    setSelected(new Set())
  }

  async function addSelected() {
    if (targetListId === '' || selected.size === 0) return
    setBusy('add')
    setError(null)
    try {
      await api.addItems(targetListId, [...selected], targetGroupId)
      setSelected(new Set())
      onItemsAdded?.()
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  async function markSeen() {
    if (selected.size === 0) return
    setBusy('seen')
    setError(null)
    try {
      await api.markStreamsSeen([...selected])
      if (onlyNew) {
        // "only new" view: seen rows no longer belong here — drop them now and
        // re-fetch the page so paging + the total stay right
        setStreams((rows) => rows.filter((r) => !selected.has(r.id)))
        setSelected(new Set())
        setStreamReload((n) => n + 1)
      } else {
        setStreams((rows) => rows.map((r) => (selected.has(r.id) ? { ...r, isNew: false } : r)))
      }
    } catch (e) {
      setError((e as Error).message)
    } finally {
      setBusy(null)
    }
  }

  return (
    <section className="panel catalog">
      <header className="panel-head">
        <h2>{t('Catalog')}</h2>
        <span className="muted">
          {showingStreams
            ? t('{n} channels (catalog)').replace('{n}', String(total))
            : t('{n} groups').replace('{n}', String(categories.length))}
        </span>
      </header>

      <div className="filter-bar">
        <input
          placeholder={t('Search (contains)…')}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        <input
          placeholder={t('Prefix (e.g. NL:)')}
          value={prefix}
          onChange={(e) => setPrefix(e.target.value)}
        />
        <select value={type} onChange={(e) => setType(e.target.value as ContentType)}>
          {CONTENT_TYPES.map((ct) => (
            <option key={ct} value={ct}>
              {ct}
            </option>
          ))}
        </select>
        <select
          value={sourceId}
          onChange={(e) => setSourceId(e.target.value === '' ? '' : Number(e.target.value))}
        >
          <option value="">{t('All sources')}</option>
          {sources.map((s) => (
            <option key={s.id} value={s.id}>
              {s.name}
            </option>
          ))}
        </select>
        <label className="inline">
          <input type="checkbox" checked={onlyNew} onChange={(e) => setOnlyNew(e.target.checked)} />
          {t('Only new')}
        </label>
      </div>

      {showingStreams && (
        <div className="catalog-toolbar">
          <span className="muted">{t('{n} selected').replace('{n}', String(selected.size))}</span>
          <label className="inline target-label">
            {t('Add to')}
            <select
              value={targetListId}
              onChange={(e) =>
                setTargetListId(e.target.value === '' ? '' : Number(e.target.value))
              }
            >
              <option value="">{t('Target list…')}</option>
              {lists.map((l) => (
                <option key={l.id} value={l.id}>
                  {l.name}
                </option>
              ))}
            </select>
          </label>
          <span className="muted">/</span>
          <select
            className={targetGroupId !== 0 ? 'target-group set' : 'target-group'}
            value={targetGroupId}
            disabled={!groupForActiveList}
            title={groupForActiveList ? undefined : t('Groups belong to the active list; target that list to pick a group')}
            onChange={(e) => setTargetGroupId(Number(e.target.value))}
          >
            <option value={0}>{t('Upstream group')}</option>
            {sortedGroups.map((g) => (
              <option key={g.id} value={g.id}>
                {g.isFavorite ? '★ ' : ''}
                {g.name}
              </option>
            ))}
          </select>
          <button
            onClick={addSelected}
            disabled={busy === 'add' || selected.size === 0 || targetListId === ''}
            title={
              targetListId === ''
                ? t('Pick a target list first')
                : t('Add {n} to {list} → {group}')
                    .replace('{n}', String(selected.size))
                    .replace('{list}', String(targetListName ?? ''))
                    .replace('{group}', targetGroupLabel)
            }
          >
            {busy === 'add'
              ? t('Adding…')
              : t('Add {n} → {group}')
                  .replace('{n}', String(selected.size || ''))
                  .replace('{group}', targetGroupLabel)
                  .replace('  ', ' ')}
          </button>
          <button onClick={markSeen} disabled={busy === 'seen' || selected.size === 0}>
            {busy === 'seen' ? t('Marking…') : t('Mark selected as seen')}
          </button>
        </div>
      )}

      {error && <p className="error">{error}</p>}

      {/* Drill / paging bar */}
      {showingStreams ? (
        <div className="catalog-nav">
          <button onClick={backToGroups}>{t('← Back to groups')}</button>
          <span className="crumb">
            {drill ? drill.name : t('Search: “{term}”').replace('{term}', searchTerm)}
          </span>
          <span className="spacer" />
          <label className="inline">
            {t('Page size')}
            <select value={pageSize} onChange={(e) => setPageSize(Number(e.target.value))}>
              {PAGE_SIZES.map((n) => (
                <option key={n} value={n}>
                  {n}
                </option>
              ))}
            </select>
          </label>
          <button onClick={() => setPage((p) => Math.max(0, p - 1))} disabled={page <= 0 || loading}>
            {t('‹ Prev')}
          </button>
          <span className="muted">
            {t('Page {page} / {count}')
              .replace('{page}', String(pageCount === 0 ? 0 : page + 1))
              .replace('{count}', String(pageCount))}
          </span>
          <button
            onClick={() => setPage((p) => Math.min(pageCount - 1, p + 1))}
            disabled={page >= pageCount - 1 || loading}
          >
            {t('Next ›')}
          </button>
        </div>
      ) : (
        <>
          {newCategoryCount > 0 && (
            <div className="catalog-nav">
              <span className="muted">{t('{n} new groups').replace('{n}', String(newCategoryCount))}</span>
              <span className="spacer" />
              <button onClick={markAllGroupsSeen}>{t('Mark all groups seen')}</button>
            </div>
          )}
          {!hasSource && (
            <p className="hint pad">
              {t('Pick a source to browse its groups, or type a search term for a flat channel list.')}
            </p>
          )}
        </>
      )}

      <div className="panel-body table-wrap">
        {loading ? (
          <p className="muted pad">{t('Loading…')}</p>
        ) : showingStreams ? (
          <table className="data-table">
            <thead>
              <tr>
                <th className="col-check">
                  <input
                    type="checkbox"
                    checked={allVisibleSelected}
                    onChange={toggleAll}
                    aria-label={t('Select all on this page')}
                  />
                </th>
                <th>{t('Name')}</th>
                <th>{t('Group')}</th>
                <th>{t('Type')}</th>
                <th>{t('Source')}</th>
                <th aria-label={t('Measure quality')} />
              </tr>
            </thead>
            <tbody>
              {streams.map((s) => (
                <tr key={s.id} className={selected.has(s.id) ? 'row-selected' : undefined}>
                  <td className="col-check">
                    <input
                      type="checkbox"
                      checked={selected.has(s.id)}
                      onChange={() => toggleOne(s.id)}
                    />
                  </td>
                  <td>
                    {s.name}
                    {s.isNew && <span className="badge new">{t('NEW')}</span>}
                    <ArchiveBadge days={s.archiveDays} />
                  </td>
                  <td className="muted">{s.groupTitle ?? '—'}</td>
                  <td className="muted">{s.contentType}</td>
                  <td className="muted">{sourceName.get(s.sourceId) ?? s.sourceId}</td>
                  <td>
                    {s.contentType === CONTENT_LIVE && (
                      <button
                        type="button"
                        className="probe-btn"
                        title={t('Measure quality: all variants of this channel')}
                        aria-label={t('Measure quality')}
                        onClick={() => setProbe(s)}
                      >
                        📊
                      </button>
                    )}
                  </td>
                </tr>
              ))}
              {streams.length === 0 && (
                <tr>
                  <td colSpan={6} className="muted center">
                    {t('No channels match.')}
                  </td>
                </tr>
              )}
            </tbody>
          </table>
        ) : (
          <ul className="group-list">
            {sortedCategories.map((c) => (
              <li key={c.id} className="group-row" onClick={() => openGroup(c)}>
                <span className="group-name">{c.name}</span>
                {c.isNew && (
                  <>
                    <span className="badge new">{t('NEW')}</span>
                    <button
                      className="seen-btn"
                      title={t('Mark this group as seen')}
                      onClick={(e) => {
                        e.stopPropagation()
                        void markGroupSeen(c)
                      }}
                    >
                      ✓
                    </button>
                  </>
                )}
                <span className="chevron">›</span>
              </li>
            ))}
            {sortedCategories.length === 0 && (
              <li className="muted center pad">
                {hasSource ? t('No groups match.') : t('Pick a source to see its groups.')}
              </li>
            )}
          </ul>
        )}
      </div>
      {probe && (
        <QualityProbeModal
          streamId={probe.id}
          title={probe.name}
          sources={sources}
          listId={activeListId}
          onClose={() => setProbe(null)}
        />
      )}
    </section>
  )
}
