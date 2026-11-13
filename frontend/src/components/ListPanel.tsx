import React, { useEffect, useMemo, useRef, useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { ContentType, CustomGroup, CustomItem, CustomList, Source, TvgIdInfo, VariantMatch } from '../types'
import {
  byChannelNumber,
  byNameCI,
  compareGroups,
  CONTENT_TYPES,
  planBouquetNumbers,
  reorderByDrag,
} from '../lib/ordering'
import { suggestTvgId } from '../lib/epgMatch'
import { Modal } from './Modal'
import { QualityProbeModal } from './QualityProbeModal'
import { ArchiveBadge } from './ArchiveBadge'
import { useT } from '../i18n'

type SortMode = 'name' | 'number'
const SORT_KEY = 'iptv.list.sortMode'
const COLLAPSE_KEY = 'iptv.list.collapsed'
// collapsed-groups are persisted PER LIST — group ids are list-specific, so a
// single shared key would carry one list's collapsed ids into another.
const collapseKey = (id: number | null) => `${COLLAPSE_KEY}.${id ?? 'none'}`
function loadCollapsed(id: number | null): Set<number> {
  try {
    return new Set<number>(JSON.parse(localStorage.getItem(collapseKey(id)) ?? '[]'))
  } catch {
    return new Set<number>()
  }
}

interface Props {
  lists: CustomList[]
  activeListId: number | null
  onSelectList: (id: number) => void
  groups: CustomGroup[]
  items: CustomItem[]
  loading: boolean
  error: string | null
  /** Refresh groups + items for the active list. */
  onRefresh: () => void
}

const UPSTREAM_GROUP_ID = 0

// Quality tiers offered when duplicating a group as another variant. Mirrors the
// backend's CanonicalQuality vocabulary (IPTV.Core.Utils). Keep the two in sync.
const QUALITIES = ['SD', 'HD', 'FHD', 'UHD', '4K', '4K+', '8K', '8K+', 'RAW'] as const

// The id from the nearest ancestor carrying data-<attr> at a screen point — used to
// hit-test which row/group is under the finger during a pointer (touch/mouse) drag.
function idUnderPoint(x: number, y: number, attr: string): number | null {
  const node = (document.elementFromPoint(x, y) as Element | null)?.closest(`[${attr}]`)
  if (!node) return null
  const v = Number(node.getAttribute(attr))
  return Number.isFinite(v) ? v : null
}

export function ListPanel({
  lists,
  activeListId,
  onSelectList,
  groups,
  items,
  loading,
  error,
  onRefresh,
}: Props) {
  const t = useT()
  const [newGroupName, setNewGroupName] = useState('')
  const [newGroupFav, setNewGroupFav] = useState(false)
  const [newGroupType, setNewGroupType] = useState<ContentType>('live')
  const [localError, setLocalError] = useState<string | null>(null)
  const [busy, setBusy] = useState(false)
  const [confirmEmptyUpstream, setConfirmEmptyUpstream] = useState(false)
  const [sortMode, setSortMode] = useState<SortMode>(
    () => (localStorage.getItem(SORT_KEY) === 'number' ? 'number' : 'name'),
  )

  function changeSortMode(m: SortMode) {
    setSortMode(m)
    localStorage.setItem(SORT_KEY, m)
  }

  // collapsed groups (persisted per list) — keyed by group id; the upstream group is 0
  const [collapsed, setCollapsed] = useState<Set<number>>(() => loadCollapsed(activeListId))
  // re-load the collapsed set when the active list changes (ids are list-specific)
  useEffect(() => {
    setCollapsed(loadCollapsed(activeListId))
  }, [activeListId])
  function persistCollapsed(next: Set<number>) {
    setCollapsed(next)
    localStorage.setItem(collapseKey(activeListId), JSON.stringify([...next]))
  }
  function toggleCollapse(id: number) {
    const next = new Set(collapsed)
    if (next.has(id)) next.delete(id)
    else next.add(id)
    persistCollapsed(next)
  }

  // known guide ids for the per-channel tvg-id picker (catalog-wide; fetch once)
  const [tvgIds, setTvgIds] = useState<TvgIdInfo[]>([])
  useEffect(() => {
    api.tvgIds().then(setTvgIds).catch(() => setTvgIds([]))
  }, [])

  // sources, for the "duplicate group from another provider" target picker
  const [sources, setSources] = useState<Source[]>([])
  // "measure quality" dialog for one channel row (all its variants, then "use this")
  const [probeItem, setProbeItem] = useState<CustomItem | null>(null)
  useEffect(() => {
    api.listSources().then(setSources).catch(() => setSources([]))
  }, [])

  const sortedGroups = useMemo(() => [...groups].sort(compareGroups), [groups])

  const itemsByGroup = useMemo(() => {
    const m = new Map<number, CustomItem[]>()
    for (const it of items) {
      const arr = m.get(it.customGroupId) ?? []
      arr.push(it)
      m.set(it.customGroupId, arr)
    }
    const cmp =
      sortMode === 'number'
        ? (a: CustomItem, b: CustomItem) =>
            byChannelNumber(a.channelNumber, displayNameOf(a), b.channelNumber, displayNameOf(b))
        : (a: CustomItem, b: CustomItem) => byNameCI(displayNameOf(a), displayNameOf(b))
    for (const arr of m.values()) arr.sort(cmp)
    return m
  }, [items, sortMode])

  function displayNameOf(it: CustomItem): string {
    return it.displayName?.trim() || it.streamName?.trim() || `#${it.streamItemId}`
  }

  async function createGroup(e: FormEvent) {
    e.preventDefault()
    if (activeListId == null || !newGroupName.trim()) return
    setBusy(true)
    setLocalError(null)
    try {
      await api.saveGroup(activeListId, {
        name: newGroupName.trim(),
        isFavorite: newGroupFav,
        contentType: newGroupType,
      })
      setNewGroupName('')
      setNewGroupFav(false)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setBusy(false)
    }
  }

  async function saveItem(patch: Partial<CustomItem> & { id: number }) {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.saveItem(activeListId, patch)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function deleteItem(id: number) {
    setLocalError(null)
    try {
      await api.deleteItem(id)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function saveGroup(patch: Partial<CustomGroup> & { id: number }) {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.saveGroup(activeListId, patch)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function deleteGroup(id: number) {
    setLocalError(null)
    try {
      await api.deleteGroup(id)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function emptyUpstream() {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.clearGroupItems(activeListId, UPSTREAM_GROUP_ID)
      setConfirmEmptyUpstream(false)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function clearGroup(id: number) {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.clearGroupItems(activeListId, id)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  async function sortGroup(id: number) {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.sortGroup(activeListId, id)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  // Drag-to-reorder works on BOTH mouse and touch via Pointer Events — HTML5
  // drag-and-drop never fires on a touchscreen (the bouquet is meant to be usable
  // on a tablet). The ⠿ grip captures the pointer (touch-action:none so the page
  // doesn't scroll while dragging from it); we hit-test the row/group under the
  // finger with elementFromPoint. Channel reorder rewrites channel numbers (1,2,3…)
  // to match the new visual order; only meaningful in channel-number sort mode.
  const dragEnabled = sortMode === 'number'

  const [dragId, setDragId] = useState<number | null>(null)
  const [overId, setOverId] = useState<number | null>(null)
  const dragSess = useRef<{ groupId: number; ids: number[] } | null>(null)

  async function applyReorder(customGroupId: number, orderedIds: number[]) {
    if (activeListId == null) return
    setLocalError(null)
    try {
      await api.reorderGroup(activeListId, customGroupId, orderedIds)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  function chanPointerDown(it: CustomItem, groupItems: CustomItem[], e: React.PointerEvent) {
    if (!dragEnabled) return
    try { (e.currentTarget as Element).setPointerCapture(e.pointerId) } catch { /* ignore */ }
    dragSess.current = { groupId: it.customGroupId, ids: groupItems.map((i) => i.id) }
    setDragId(it.id)
    setOverId(null)
  }
  function chanPointerMove(e: React.PointerEvent) {
    if (dragId == null) return
    const t = idUnderPoint(e.clientX, e.clientY, 'data-item-id')
    if (t != null && dragSess.current?.ids.includes(t)) setOverId(t) // same group only
  }
  function chanPointerUp() {
    const sess = dragSess.current
    const dragged = dragId
    const target = overId
    dragSess.current = null
    setDragId(null)
    setOverId(null)
    if (sess && dragged != null && target != null && dragged !== target) {
      const next = reorderByDrag(sess.ids, dragged, target)
      if (next.join(',') !== sess.ids.join(',')) applyReorder(sess.groupId, next)
    }
  }

  // GROUP drag-to-reorder (favorites stay pinned on top server-side, so a group can
  // only move within its own favorite/non-favorite partition).
  const [groupDragId, setGroupDragId] = useState<number | null>(null)
  const [groupOverId, setGroupOverId] = useState<number | null>(null)
  const groupSess = useRef<number[] | null>(null)

  function groupPointerDown(g: CustomGroup, e: React.PointerEvent) {
    try { (e.currentTarget as Element).setPointerCapture(e.pointerId) } catch { /* ignore */ }
    groupSess.current = sortedGroups.map((x) => x.id)
    setGroupDragId(g.id)
    setGroupOverId(null)
  }
  function groupPointerMove(e: React.PointerEvent) {
    if (groupDragId == null) return
    const t = idUnderPoint(e.clientX, e.clientY, 'data-group-id')
    if (t == null || t === groupDragId) return
    // ignore a target across the favorite boundary — it would be re-pinned on reload
    const dg = sortedGroups.find((x) => x.id === groupDragId)
    const tg = sortedGroups.find((x) => x.id === t)
    if (dg && tg && dg.isFavorite === tg.isFavorite) setGroupOverId(t)
  }
  async function groupPointerUp() {
    const ids = groupSess.current
    const dragged = groupDragId
    const target = groupOverId
    groupSess.current = null
    setGroupDragId(null)
    setGroupOverId(null)
    if (!ids || dragged == null || target == null || dragged === target || activeListId == null)
      return
    const next = reorderByDrag(ids, dragged, target)
    if (next.join(',') === ids.join(',')) return
    setLocalError(null)
    try {
      await api.reorderGroups(activeListId, next)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  const [dedupeMsg, setDedupeMsg] = useState<string | null>(null)
  async function dedupe() {
    if (activeListId == null) return
    setLocalError(null)
    setDedupeMsg(null)
    try {
      const r = await api.dedupeList(activeListId)
      setDedupeMsg(
        r.removed > 0
          ? t('{n} duplicates removed').replace('{n}', String(r.removed))
          : t('no duplicates found'),
      )
      if (r.removed > 0) onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    }
  }

  // Bouquet-wide renumber: every group gets its own round block (next hundred, or
  // next thousand for > 99 channels), in the order shown — reviewed in a modal first.
  const renumberPlan = useMemo(() => {
    const order = [
      ...sortedGroups.map((g) => ({ groupId: g.id, name: g.name })),
      { groupId: UPSTREAM_GROUP_ID, name: t('Upstream group') },
    ]
    const plan = planBouquetNumbers(
      order.map((g) => ({ groupId: g.groupId, itemIds: (itemsByGroup.get(g.groupId) ?? []).map((it) => it.id) })),
    )
    const names = new Map(order.map((g) => [g.groupId, g.name]))
    return { ...plan, names }
  }, [sortedGroups, itemsByGroup, t])
  const [renumberOpen, setRenumberOpen] = useState(false)
  const [renumberBusy, setRenumberBusy] = useState(false)
  const [renumberMsg, setRenumberMsg] = useState<string | null>(null)
  async function applyRenumber() {
    if (activeListId == null) return
    setRenumberBusy(true)
    setLocalError(null)
    try {
      const r = await api.renumberList(activeListId, renumberPlan.numbers)
      setRenumberMsg(t('{n} channels renumbered').replace('{n}', String(r.numbered)))
      setRenumberOpen(false)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setRenumberBusy(false)
    }
  }

  // EPG-id suggestions: for channels that don't resolve to a known guide id, fuzzy-
  // match the channel name to the known tvg-ids and propose an override. Shown in a
  // review modal (per-channel opt-in) before anything is written.
  const [epgSuggestions, setEpgSuggestions] = useState<
    { item: CustomItem; tvgId: string; sampleName: string; score: number }[] | null
  >(null)
  const [epgAccepted, setEpgAccepted] = useState<Set<number>>(new Set())
  const [epgBusy, setEpgBusy] = useState(false)
  const [epgMsg, setEpgMsg] = useState<string | null>(null)

  function suggestEpgIds() {
    setEpgMsg(null)
    const knownIds = new Set(tvgIds.map((k) => k.tvgId))
    const out: { item: CustomItem; tvgId: string; sampleName: string; score: number }[] = []
    for (const it of items) {
      const eff = it.tvgIdOverride?.trim() || it.streamTvgId?.trim() || ''
      if (eff !== '' && knownIds.has(eff)) continue // already has a known guide id
      const name = it.displayName?.trim() || it.streamName?.trim() || ''
      if (!name) continue
      const s = suggestTvgId(name, tvgIds)
      if (s && s.tvgId !== eff)
        out.push({ item: it, tvgId: s.tvgId, sampleName: s.name, score: s.score })
    }
    out.sort((a, b) => b.score - a.score)
    if (out.length === 0) {
      setEpgMsg(t('No EPG-id suggestions (every channel already resolves, or no good match).'))
      return
    }
    setEpgAccepted(new Set(out.map((o) => o.item.id))) // default: accept all
    setEpgSuggestions(out)
  }

  function toggleEpgAccept(id: number, on: boolean) {
    setEpgAccepted((prev) => {
      const next = new Set(prev)
      if (on) next.add(id)
      else next.delete(id)
      return next
    })
  }

  async function applyEpgSuggestions() {
    if (epgSuggestions == null || activeListId == null) return
    setEpgBusy(true)
    setLocalError(null)
    try {
      const chosen = epgSuggestions.filter((s) => epgAccepted.has(s.item.id))
      for (const s of chosen)
        await api.saveItem(activeListId, { id: s.item.id, tvgIdOverride: s.tvgId })
      setEpgSuggestions(null)
      setEpgMsg(t('Set EPG-id on {n} channels.').replace('{n}', String(chosen.length)))
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setEpgBusy(false)
    }
  }

  // Duplicate a group, swapping each channel for a variant — either another
  // QUALITY (SD/HD/UHD/4K/…) or the same channel from another PROVIDER (source).
  // Two-phase modal: pick the transform + new name, then review the per-channel
  // mapping before it's created. Channels with no variant are flagged and left out
  // (they stay in the source group). A candidate already on the list can't be
  // re-added (UNIQUE(list_id, stream_item_id)).
  type VariantMode = 'quality' | 'provider'
  // 'replace' = swap the channels IN this group (same rows: channel number, logo /
  // tvg-id overrides kept); 'copy' = create a new group with the variants
  type VariantTarget = 'replace' | 'copy'
  const [variantGroup, setVariantGroup] = useState<CustomGroup | null>(null)
  const [variantMode, setVariantMode] = useState<VariantMode>('quality')
  const [variantTarget, setVariantTarget] = useState<VariantTarget>('replace')
  const [variantQuality, setVariantQuality] = useState<string>('UHD')
  const [variantSourceId, setVariantSourceId] = useState<number>(0)
  const [variantName, setVariantName] = useState('')
  const [variantNameTouched, setVariantNameTouched] = useState(false)
  const [variantRows, setVariantRows] = useState<VariantMatch[] | null>(null)
  const [variantAccepted, setVariantAccepted] = useState<Set<number>>(new Set())
  const [variantBusy, setVariantBusy] = useState(false)
  const [variantMsg, setVariantMsg] = useState<string | null>(null)

  const variantSourceName = (id: number) => sources.find((s) => s.id === id)?.name ?? ''
  // provider of a channel on the list ('' when its upstream stream is gone)
  const sourceName = (id?: number) => (id ? (sources.find((s) => s.id === id)?.name ?? `#${id}`) : '')
  // suffix that describes the chosen transform, used in the auto group name + messages
  function variantSuffix(mode: VariantMode, quality: string, sourceId: number): string {
    return mode === 'quality' ? quality : variantSourceName(sourceId) || t('other provider')
  }

  function openVariant(g: CustomGroup) {
    const firstSource = sources[0]?.id ?? 0
    setVariantGroup(g)
    setVariantMode('quality')
    setVariantTarget('replace')
    setVariantQuality('UHD')
    setVariantSourceId(firstSource)
    setVariantName(`${g.name} UHD`)
    setVariantNameTouched(false)
    setVariantRows(null)
    setVariantMsg(null)
  }
  function closeVariant() {
    setVariantGroup(null)
    setVariantRows(null)
  }
  // keep the suggested name in step with the chosen transform until the user edits it
  function syncName(mode: VariantMode, quality: string, sourceId: number) {
    if (variantGroup && !variantNameTouched)
      setVariantName(`${variantGroup.name} ${variantSuffix(mode, quality, sourceId)}`.trim())
  }
  function changeVariantMode(m: VariantMode) {
    setVariantMode(m)
    let sid = variantSourceId
    if (m === 'provider' && !sources.some((s) => s.id === sid)) {
      sid = sources[0]?.id ?? 0
      setVariantSourceId(sid)
    }
    syncName(m, variantQuality, sid)
  }
  // if sources arrive after the dialog is already in provider mode, pick a valid one
  useEffect(() => {
    if (variantMode === 'provider' && !sources.some((s) => s.id === variantSourceId) && sources[0])
      setVariantSourceId(sources[0].id)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [sources, variantMode])
  function changeVariantQuality(q: string) {
    setVariantQuality(q)
    syncName(variantMode, q, variantSourceId)
  }
  function changeVariantSource(id: number) {
    setVariantSourceId(id)
    syncName(variantMode, variantQuality, id)
  }

  async function findVariants() {
    if (activeListId == null || variantGroup == null) return
    if (variantMode === 'provider' && !variantSourceId) return
    setVariantBusy(true)
    setLocalError(null)
    try {
      const rows =
        variantMode === 'quality'
          ? await api.groupVariants(activeListId, variantGroup.id, variantQuality)
          : await api.groupProviderVariants(activeListId, variantGroup.id, variantSourceId)
      setVariantRows(rows)
      // default-accept every channel that has a usable variant (matched, not already here)
      setVariantAccepted(new Set(rows.filter((r) => r.matched && !r.alreadyInList).map((r) => r.itemId)))
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setVariantBusy(false)
    }
  }

  function toggleVariantAccept(itemId: number, on: boolean) {
    setVariantAccepted((prev) => {
      const next = new Set(prev)
      if (on) next.add(itemId)
      else next.delete(itemId)
      return next
    })
  }

  async function applyVariant() {
    if (activeListId == null || variantGroup == null || variantRows == null) return
    const chosen = variantRows.filter(
      (r) => r.matched && !r.alreadyInList && variantAccepted.has(r.itemId),
    )
    if (chosen.length === 0) return
    setVariantBusy(true)
    setLocalError(null)
    if (variantTarget === 'replace') {
      try {
        const r = await api.replaceItems(
          activeListId,
          chosen.map((c) => ({ itemId: c.itemId, streamId: c.candidateStreamId })),
        )
        const groupName = variantGroup.name
        closeVariant()
        setVariantMsg(
          t('Replaced {n} channels in “{name}”.')
            .replace('{n}', String(r.replaced))
            .replace('{name}', groupName),
        )
        onRefresh()
      } catch (err) {
        setLocalError((err as Error).message)
      } finally {
        setVariantBusy(false)
      }
      return
    }
    try {
      const fallback = `${variantGroup.name} ${variantSuffix(variantMode, variantQuality, variantSourceId)}`.trim()
      const grp = await api.saveGroup(activeListId, {
        name: variantName.trim() || fallback,
        isFavorite: false,
        contentType: variantGroup.contentType,
      })
      await api.addItems(activeListId, chosen.map((r) => r.candidateStreamId), grp.id)
      closeVariant()
      setVariantMsg(
        t('Created “{name}” with {n} channels.')
          .replace('{name}', grp.name)
          .replace('{n}', String(chosen.length)),
      )
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setVariantBusy(false)
    }
  }

  // Clean the names of an EXISTING group after the fact: apply the sources' strip
  // prefixes/suffixes (+ optional one-off tokens) to what each channel shows now.
  // Preview first (dry run), then apply.
  type NameChange = { itemId: number; oldName: string; newName: string; original: string }
  const [cleanGroup, setCleanGroup] = useState<CustomGroup | null>(null)
  const [cleanPrefixes, setCleanPrefixes] = useState('')
  const [cleanSuffixes, setCleanSuffixes] = useState('')
  const [cleanRows, setCleanRows] = useState<NameChange[] | null>(null)
  const [cleanBusy, setCleanBusy] = useState(false)
  const splitTokens = (raw: string) =>
    raw.split(';').map((s) => s.trim()).filter((s) => s.length > 0)

  async function previewClean(g: CustomGroup, pfx: string, sfx: string) {
    if (activeListId == null) return
    setCleanBusy(true)
    setLocalError(null)
    try {
      setCleanRows(
        await api.restripGroup(activeListId, g.id, {
          extraPrefixes: splitTokens(pfx),
          extraSuffixes: splitTokens(sfx),
          dryRun: true,
        }),
      )
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setCleanBusy(false)
    }
  }
  function openClean(g: CustomGroup) {
    setCleanGroup(g)
    setCleanPrefixes('')
    setCleanSuffixes('')
    setCleanRows(null)
    void previewClean(g, '', '') // show at once what the source rules would do
  }
  async function applyClean() {
    if (activeListId == null || cleanGroup == null) return
    setCleanBusy(true)
    setLocalError(null)
    try {
      const done = await api.restripGroup(activeListId, cleanGroup.id, {
        extraPrefixes: splitTokens(cleanPrefixes),
        extraSuffixes: splitTokens(cleanSuffixes),
        dryRun: false,
      })
      setVariantMsg(
        t('Cleaned {n} channel names in “{name}”.')
          .replace('{n}', String(done.length))
          .replace('{name}', cleanGroup.name),
      )
      setCleanGroup(null)
      setCleanRows(null)
      onRefresh()
    } catch (err) {
      setLocalError((err as Error).message)
    } finally {
      setCleanBusy(false)
    }
  }

  // human label for the chosen transform, used in the review "not found" flags
  const variantLabel = variantMode === 'quality' ? variantQuality : variantSourceName(variantSourceId)

  const hasUpstreamItems = itemsByGroup.has(UPSTREAM_GROUP_ID)
  const isEmpty = sortedGroups.length === 0 && !hasUpstreamItems

  // collapse-all / expand-all over every visible group (custom + upstream)
  const collapsibleIds = sortedGroups.map((g) => g.id)
  if (hasUpstreamItems) collapsibleIds.push(UPSTREAM_GROUP_ID)
  const allCollapsed =
    collapsibleIds.length > 0 && collapsibleIds.every((id) => collapsed.has(id))
  function toggleAllCollapse() {
    persistCollapsed(allCollapsed ? new Set<number>() : new Set<number>(collapsibleIds))
  }

  return (
    <section className="panel">
      {/* shared options for every channel's tvg-id picker (searchable by id or name) */}
      <datalist id="iptv-tvgids">
        {tvgIds.map((t) => (
          <option key={t.tvgId} value={t.tvgId}>
            {t.tvgId} — {t.name}
          </option>
        ))}
      </datalist>
      <header className="panel-head">
        <h2>{t('Bouquet')}</h2>
        <select
          value={activeListId ?? ''}
          onChange={(e) => onSelectList(Number(e.target.value))}
        >
          <option value="" disabled>
            {t('Pick a list…')}
          </option>
          {lists.map((l) => (
            <option key={l.id} value={l.id}>
              {l.name}
            </option>
          ))}
        </select>
        {activeListId != null && (
          <span className="exports">
            <a href={api.exportM3uUrl(activeListId)} download title={t('Download playlist as M3U')}>
              {t('⬇ .m3u')}
            </a>
            <a href={api.exportXmltvUrl(activeListId)} download title={t('Download EPG as XMLTV')}>
              {t('⬇ EPG')}
            </a>
          </span>
        )}
      </header>

      {(error || localError) && <p className="error">{error ?? localError}</p>}

      {activeListId == null ? (
        <div className="panel-body">
          <p className="muted">{t('Select a list to curate.')}</p>
        </div>
      ) : (
        <>
          <form className="group-form" onSubmit={createGroup}>
            <input
              placeholder={t('New group name')}
              value={newGroupName}
              onChange={(e) => setNewGroupName(e.target.value)}
            />
            <select
              value={newGroupType}
              onChange={(e) => setNewGroupType(e.target.value as ContentType)}
            >
              {CONTENT_TYPES.map((ct) => (
                <option key={ct} value={ct}>
                  {ct}
                </option>
              ))}
            </select>
            <label className="inline">
              <input
                type="checkbox"
                checked={newGroupFav}
                onChange={(e) => setNewGroupFav(e.target.checked)}
              />
              {t('Favorite')}
            </label>
            <button type="submit" disabled={busy || !newGroupName.trim()}>
              {t('Add group')}
            </button>
            <button
              type="button"
              onClick={dedupe}
              title={t('Remove duplicate channels (same upstream URL), keeping one')}
            >
              {t('Dedupe')}
            </button>
            {dedupeMsg && <span className="muted">{dedupeMsg}</span>}
            <button
              type="button"
              onClick={() => {
                setRenumberMsg(null)
                setRenumberOpen(true)
              }}
              disabled={items.length === 0}
              title={t('Number all channels across all groups: each group starts on a new hundred (a thousand for groups over 99 channels)')}
            >
              {t('Renumber bouquet')}
            </button>
            {renumberMsg && <span className="muted">{renumberMsg}</span>}
            <button
              type="button"
              onClick={suggestEpgIds}
              title={t('Match channel names to known guide ids (tvg-id) and propose an EPG id for channels that have none')}
            >
              {t('Suggest EPG-ids')}
            </button>
            {epgMsg && <span className="muted">{epgMsg}</span>}
            {variantMsg && <span className="muted">{variantMsg}</span>}
            <span className="sort-toggle" role="group" aria-label={t('Sort channels by')}>
              <span className="muted">{t('Sort:')}</span>
              <button
                type="button"
                className={sortMode === 'name' ? 'active' : ''}
                aria-pressed={sortMode === 'name'}
                onClick={() => changeSortMode('name')}
                title={t('Order channels A→Z by name')}
              >
                {t('Name')}
              </button>
              <button
                type="button"
                className={sortMode === 'number' ? 'active' : ''}
                aria-pressed={sortMode === 'number'}
                onClick={() => changeSortMode('number')}
                title={t('Order channels by channel number (lowest first; unset last)')}
              >
                {t('No.')}
              </button>
            </span>
            {sortMode === 'number' && (
              <span className="muted hint">{t('⠿ drag channels to set the numbering')}</span>
            )}
            {!isEmpty && (
              <button
                type="button"
                onClick={toggleAllCollapse}
                title={allCollapsed ? t('Expand all groups') : t('Collapse all groups')}
              >
                {allCollapsed ? t('⊞ Expand all') : t('⊟ Collapse all')}
              </button>
            )}
          </form>

          <div className="panel-body">
            {loading ? (
              <p className="muted">{t('Loading…')}</p>
            ) : isEmpty ? (
              <p className="muted">{t('No groups or items yet.')}</p>
            ) : (
              <>
                {/* custom groups (renamable), favorites first then A→Z */}
                {sortedGroups.map((g) => (
                  <div
                    key={g.id}
                    data-group-id={g.id}
                    className={
                      'group-block' +
                      (groupOverId === g.id && groupDragId != null && groupDragId !== g.id
                        ? ' drop-target'
                        : '')
                    }
                  >
                    <GroupHeader
                      group={g}
                      count={(itemsByGroup.get(g.id) ?? []).length}
                      collapsed={collapsed.has(g.id)}
                      onToggleCollapse={() => toggleCollapse(g.id)}
                      onSave={saveGroup}
                      onDelete={deleteGroup}
                      onClear={clearGroup}
                      onSort={sortGroup}
                      onDuplicateVariant={openVariant}
                      onCleanNames={openClean}
                      dragHandle={{
                        onDown: (e) => groupPointerDown(g, e),
                        onMove: groupPointerMove,
                        onUp: groupPointerUp,
                      }}
                    />
                    {!collapsed.has(g.id) && (
                      <ul className="item-list">
                        {(itemsByGroup.get(g.id) ?? []).map((it) => (
                          <ItemRow
                            // key includes the server-controlled fields so the row
                            // remounts (re-syncs its inputs) after drag-reorder / sort
                            // / group-move changes the item underneath it
                            key={`${it.id}:${it.streamItemId}:${it.channelNumber}:${it.customGroupId}:${it.displayName ?? ''}:${it.logoOverride ?? ''}:${it.tvgIdOverride ?? ''}`}
                            item={it}
                            sourceName={sourceName(it.streamSourceId)}
                            groups={sortedGroups}
                            onSave={saveItem}
                            onDelete={deleteItem}
                            onProbe={setProbeItem}
                            drag={
                              dragEnabled
                                ? {
                                    isDragging: dragId === it.id,
                                    isOver: overId === it.id && dragId !== it.id,
                                    onDown: (e) => chanPointerDown(it, itemsByGroup.get(g.id) ?? [], e),
                                    onMove: chanPointerMove,
                                    onUp: chanPointerUp,
                                  }
                                : undefined
                            }
                          />
                        ))}
                      </ul>
                    )}
                  </div>
                ))}

                {/* upstream group (id 0): channels keeping their provider group, not renamable */}
                {hasUpstreamItems && (
                  <div className="group-block">
                    <h4 className="group-title">
                      <button
                        type="button"
                        className="collapse-btn"
                        aria-expanded={!collapsed.has(UPSTREAM_GROUP_ID)}
                        title={collapsed.has(UPSTREAM_GROUP_ID) ? t('Expand') : t('Collapse')}
                        onClick={() => toggleCollapse(UPSTREAM_GROUP_ID)}
                      >
                        {collapsed.has(UPSTREAM_GROUP_ID) ? '▸' : '▾'}
                      </button>
                      <span className="group-label">{t('Upstream group')}</span>
                      <span className="muted count">
                        {(itemsByGroup.get(UPSTREAM_GROUP_ID) ?? []).length}
                      </span>
                      {confirmEmptyUpstream ? (
                        <>
                          <button className="group-edit danger" onClick={emptyUpstream}>
                            {t('Confirm empty')}
                          </button>
                          <button className="group-edit" onClick={() => setConfirmEmptyUpstream(false)}>
                            {t('Cancel')}
                          </button>
                        </>
                      ) : (
                        <button
                          className="group-edit danger"
                          title={t('Remove all channels from the upstream group')}
                          onClick={() => setConfirmEmptyUpstream(true)}
                        >
                          {t('🗑 Empty')}
                        </button>
                      )}
                    </h4>
                    {!collapsed.has(UPSTREAM_GROUP_ID) && (
                      <ul className="item-list">
                        {(itemsByGroup.get(UPSTREAM_GROUP_ID) ?? []).map((it) => (
                          <ItemRow
                            // key includes the server-controlled fields so the row
                            // remounts (re-syncs its inputs) after drag-reorder / sort
                            // / group-move changes the item underneath it
                            key={`${it.id}:${it.streamItemId}:${it.channelNumber}:${it.customGroupId}:${it.displayName ?? ''}:${it.logoOverride ?? ''}:${it.tvgIdOverride ?? ''}`}
                            item={it}
                            sourceName={sourceName(it.streamSourceId)}
                            groups={sortedGroups}
                            onSave={saveItem}
                            onDelete={deleteItem}
                            onProbe={setProbeItem}
                            drag={
                              dragEnabled
                                ? {
                                    isDragging: dragId === it.id,
                                    isOver: overId === it.id && dragId !== it.id,
                                    onDown: (e) => chanPointerDown(it, itemsByGroup.get(UPSTREAM_GROUP_ID) ?? [], e),
                                    onMove: chanPointerMove,
                                    onUp: chanPointerUp,
                                  }
                                : undefined
                            }
                          />
                        ))}
                      </ul>
                    )}
                  </div>
                )}
              </>
            )}
          </div>
        </>
      )}

      {renumberOpen && (
        <Modal
          title={t('Renumber bouquet')}
          onClose={() => setRenumberOpen(false)}
          footer={
            <>
              <button onClick={() => setRenumberOpen(false)}>{t('Cancel')}</button>
              <button
                className="primary"
                disabled={renumberBusy || renumberPlan.numbers.length === 0}
                onClick={() => void applyRenumber()}
              >
                {t('Renumber {n} channels').replace('{n}', String(renumberPlan.numbers.length))}
              </button>
            </>
          }
        >
          <p className="hint">
            {t('Groups in the order shown, channels in their current order. Each group starts on a new hundred; a group with more than 99 channels starts on a new thousand.')}
          </p>
          <table className="data-table">
            <thead>
              <tr>
                <th>{t('Group')}</th>
                <th>{t('Channels')}</th>
                <th>{t('Numbers')}</th>
              </tr>
            </thead>
            <tbody>
              {renumberPlan.blocks.map((b) => (
                <tr key={b.groupId}>
                  <td>{renumberPlan.names.get(b.groupId)}</td>
                  <td>{b.count}</td>
                  <td>
                    {b.first} – {b.last}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </Modal>
      )}

      {probeItem && (
        <QualityProbeModal
          streamId={probeItem.streamItemId}
          title={probeItem.displayName?.trim() || probeItem.streamName?.trim() || `#${probeItem.streamItemId}`}
          sources={sources}
          listId={activeListId}
          item={probeItem}
          onReplaced={onRefresh}
          onClose={() => setProbeItem(null)}
        />
      )}

      {epgSuggestions && (
        <Modal
          title={t('EPG-id suggestions')}
          onClose={() => setEpgSuggestions(null)}
          footer={
            <>
              <button type="button" disabled={epgBusy || epgAccepted.size === 0} onClick={applyEpgSuggestions}>
                {epgBusy ? t('Applying…') : t('Apply ({n})').replace('{n}', String(epgAccepted.size))}
              </button>
              <button type="button" onClick={() => setEpgSuggestions(null)}>
                {t('Cancel')}
              </button>
            </>
          }
        >
          <p className="hint">
            {t('Tick the channels to set the suggested guide id (tvg-id). Best matches first; review before applying.')}
          </p>
          <ul className="epg-suggest-list">
            {epgSuggestions.map((s) => (
              <li key={s.item.id}>
                <label className="inline">
                  <input
                    type="checkbox"
                    checked={epgAccepted.has(s.item.id)}
                    onChange={(e) => toggleEpgAccept(s.item.id, e.target.checked)}
                  />
                  <span className="epg-suggest-name">
                    {s.item.displayName?.trim() || s.item.streamName || `#${s.item.streamItemId}`}
                  </span>
                  <span className="muted"> → </span>
                  <code>{s.tvgId}</code>
                  <span className="muted"> ({s.sampleName})</span>
                </label>
              </li>
            ))}
          </ul>
        </Modal>
      )}

      {variantGroup && (
        <Modal
          title={(variantTarget === 'replace' ? t('Replace channels in “{name}”') : t('Duplicate “{name}”')).replace(
            '{name}',
            variantGroup.name,
          )}
          onClose={closeVariant}
          footer={
            variantRows == null ? (
              <>
                <button
                  type="button"
                  disabled={variantBusy || (variantMode === 'provider' && !variantSourceId)}
                  onClick={findVariants}
                >
                  {variantBusy ? t('Searching…') : t('Find variants')}
                </button>
                <button type="button" onClick={closeVariant}>
                  {t('Cancel')}
                </button>
              </>
            ) : (
              <>
                <button
                  type="button"
                  disabled={variantBusy || variantAccepted.size === 0}
                  onClick={applyVariant}
                >
                  {variantTarget === 'replace'
                    ? variantBusy
                      ? t('Replacing…')
                      : t('Replace {n} channels').replace('{n}', String(variantAccepted.size))
                    : variantBusy
                      ? t('Creating…')
                      : t('Create group ({n})').replace('{n}', String(variantAccepted.size))}
                </button>
                <button type="button" onClick={() => setVariantRows(null)}>
                  {t('Back')}
                </button>
                <button type="button" onClick={closeVariant}>
                  {t('Cancel')}
                </button>
              </>
            )
          }
        >
          {variantRows == null ? (
            <div className="variant-setup">
              <span className="sort-toggle" role="group" aria-label={t('Where')}>
                <span className="muted">{t('Where:')}</span>
                <button
                  type="button"
                  className={variantTarget === 'replace' ? 'active' : ''}
                  aria-pressed={variantTarget === 'replace'}
                  onClick={() => setVariantTarget('replace')}
                >
                  {t('In this group')}
                </button>
                <button
                  type="button"
                  className={variantTarget === 'copy' ? 'active' : ''}
                  aria-pressed={variantTarget === 'copy'}
                  onClick={() => setVariantTarget('copy')}
                >
                  {t('Copy to a new group')}
                </button>
              </span>
              <p className="hint">
                {variantTarget === 'replace'
                  ? t('Swap each channel in this group for a variant, in place: channel number, logo and EPG-id stay. Channels with no variant are left as they are. You can untick channels in the next step.')
                  : t('Make a copy of this group where each channel is swapped for a variant. Channels with no variant are skipped (they stay in the original group).')}
              </p>
              <span className="sort-toggle" role="group" aria-label={t('Replace by')}>
                <span className="muted">{t('Replace by:')}</span>
                <button
                  type="button"
                  className={variantMode === 'quality' ? 'active' : ''}
                  aria-pressed={variantMode === 'quality'}
                  onClick={() => changeVariantMode('quality')}
                >
                  {t('Quality')}
                </button>
                <button
                  type="button"
                  className={variantMode === 'provider' ? 'active' : ''}
                  aria-pressed={variantMode === 'provider'}
                  onClick={() => changeVariantMode('provider')}
                >
                  {t('Provider')}
                </button>
              </span>
              {variantMode === 'quality' ? (
                <label>
                  {t('Target quality')}
                  <select value={variantQuality} onChange={(e) => changeVariantQuality(e.target.value)}>
                    {QUALITIES.map((q) => (
                      <option key={q} value={q}>
                        {q}
                      </option>
                    ))}
                  </select>
                </label>
              ) : (
                <label>
                  {t('Replacement provider')}
                  {sources.length === 0 ? (
                    <span className="muted"> {t('(no sources)')}</span>
                  ) : (
                    <select
                      value={variantSourceId}
                      onChange={(e) => changeVariantSource(Number(e.target.value))}
                    >
                      {sources.map((s) => (
                        <option key={s.id} value={s.id}>
                          {s.name}
                        </option>
                      ))}
                    </select>
                  )}
                </label>
              )}
              {variantTarget === 'copy' && (
                <label>
                  {t('New group name')}
                  <input
                    value={variantName}
                    onChange={(e) => {
                      setVariantNameTouched(true)
                      setVariantName(e.target.value)
                    }}
                  />
                </label>
              )}
            </div>
          ) : variantRows.length === 0 ? (
            <p className="muted">{t('This group has no channels.')}</p>
          ) : (
            <>
              <p className="hint">
                {(variantTarget === 'replace'
                  ? t('Review the {q} variant for each channel. Ticked channels are replaced in this group; unmatched ones stay as they are.')
                  : t('Review the {q} variant for each channel. Ticked channels go into the new group; unmatched ones are flagged and left out.')
                ).replace('{q}', variantLabel)}
              </p>
              <ul className="epg-suggest-list">
                {variantRows.map((r) => (
                  <li key={r.itemId}>
                    {r.matched && !r.alreadyInList ? (
                      <label className="inline">
                        <input
                          type="checkbox"
                          checked={variantAccepted.has(r.itemId)}
                          onChange={(e) => toggleVariantAccept(r.itemId, e.target.checked)}
                        />
                        <span className="epg-suggest-name">{r.name}</span>
                        <span className="muted"> → </span>
                        <span>{r.candidateName}</span>
                      </label>
                    ) : (
                      <span className="inline">
                        <span className="epg-suggest-name">{r.name}</span>
                        <span className="muted">
                          {' '}
                          {r.alreadyInList
                            ? t('— {q} variant already on this list').replace('{q}', variantLabel)
                            : t('— no {q} variant found').replace('{q}', variantLabel)}
                        </span>
                      </span>
                    )}
                  </li>
                ))}
              </ul>
            </>
          )}
        </Modal>
      )}

      {cleanGroup && (
        <Modal
          title={t('Clean names in “{name}”').replace('{name}', cleanGroup.name)}
          onClose={() => setCleanGroup(null)}
          footer={
            <>
              <button
                type="button"
                disabled={cleanBusy || !cleanRows || cleanRows.length === 0}
                onClick={applyClean}
              >
                {cleanBusy
                  ? t('Working…')
                  : t('Apply ({n})').replace('{n}', String(cleanRows?.length ?? 0))}
              </button>
              <button type="button" onClick={() => setCleanGroup(null)}>
                {t('Cancel')}
              </button>
            </>
          }
        >
          <p className="hint">
            {t('Strips the sources’ prefixes/suffixes — plus any extra tokens below — from the names the channels in this group show now. Manual names only change when they contain such a token. The original name stays visible.')}
          </p>
          <label>
            {t('Extra prefixes')}
            <input
              value={cleanPrefixes}
              placeholder={t('e.g. NL; UK')}
              onChange={(e) => setCleanPrefixes(e.target.value)}
            />
          </label>
          <label>
            {t('Extra suffixes')}
            <input
              value={cleanSuffixes}
              placeholder={t('e.g. (S); rec')}
              onChange={(e) => setCleanSuffixes(e.target.value)}
            />
          </label>
          <button
            type="button"
            disabled={cleanBusy}
            onClick={() => previewClean(cleanGroup, cleanPrefixes, cleanSuffixes)}
          >
            {t('Preview')}
          </button>
          {cleanRows == null ? (
            <p className="muted">{t('Searching…')}</p>
          ) : cleanRows.length === 0 ? (
            <p className="muted">{t('Nothing to strip — all names are already clean.')}</p>
          ) : (
            <ul className="epg-suggest-list">
              {cleanRows.map((r) => (
                <li key={r.itemId}>
                  <span className="epg-suggest-name">{r.oldName}</span>
                  <span className="muted"> → </span>
                  <span>{r.newName}</span>
                </li>
              ))}
            </ul>
          )}
        </Modal>
      )}
    </section>
  )
}

interface GroupHeaderProps {
  group: CustomGroup
  count: number
  collapsed: boolean
  onToggleCollapse: () => void
  onSave: (patch: Partial<CustomGroup> & { id: number }) => void
  onDelete: (id: number) => void
  onClear: (id: number) => void
  onSort: (id: number) => void
  onDuplicateVariant: (group: CustomGroup) => void
  /** open the "clean names" dialog (strip prefixes/suffixes after the fact) */
  onCleanNames?: (group: CustomGroup) => void
  /** when set, a drag handle (⠿) appears to reorder groups (pointer = mouse+touch) */
  dragHandle?: {
    onDown: (e: React.PointerEvent) => void
    onMove: (e: React.PointerEvent) => void
    onUp: (e: React.PointerEvent) => void
  }
}

/** Header for a user-created group: collapse, rename inline, toggle favorite, sort, empty, delete. */
function GroupHeader({ group, count, collapsed, onToggleCollapse, onSave, onDelete, onClear, onSort, onDuplicateVariant, onCleanNames, dragHandle }: GroupHeaderProps) {
  const t = useT()
  const [editing, setEditing] = useState(false)
  const [name, setName] = useState(group.name)
  const [confirmEmpty, setConfirmEmpty] = useState(false)

  function commit() {
    const n = name.trim()
    if (n && n !== group.name) onSave({ id: group.id, name: n })
    setEditing(false)
  }
  function cancel() {
    setName(group.name)
    setEditing(false)
  }

  if (editing) {
    return (
      <h4 className="group-title editing">
        <input
          autoFocus
          value={name}
          onChange={(e) => setName(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === 'Enter') commit()
            else if (e.key === 'Escape') cancel()
          }}
        />
        <button type="button" onClick={commit} disabled={!name.trim()}>
          {t('Save')}
        </button>
        <button type="button" onClick={cancel}>
          {t('Cancel')}
        </button>
      </h4>
    )
  }

  return (
    <h4 className="group-title">
      {dragHandle && (
        <span
          className="group-grip"
          style={{ touchAction: 'none' }}
          aria-label={t('Reorder group')}
          title={t('Drag to reorder groups')}
          onPointerDown={dragHandle.onDown}
          onPointerMove={dragHandle.onMove}
          onPointerUp={dragHandle.onUp}
        >
          ⠿
        </span>
      )}
      <button
        type="button"
        className="collapse-btn"
        aria-expanded={!collapsed}
        title={collapsed ? t('Expand') : t('Collapse')}
        onClick={onToggleCollapse}
      >
        {collapsed ? '▸' : '▾'}
      </button>
      <button
        type="button"
        className="star-btn"
        title={group.isFavorite ? t('Unmark favorite') : t('Mark favorite')}
        onClick={() => onSave({ id: group.id, isFavorite: !group.isFavorite })}
      >
        {group.isFavorite ? '★' : '☆'}
      </button>
      <span className="group-label">{group.name}</span>
      <span className="muted count">{count}</span>
      <button type="button" className="group-edit" title={t('Rename')} onClick={() => setEditing(true)}>
        ✎
      </button>
      <button
        type="button"
        className="group-edit"
        title={t("Sort this group's channels A→Z (renumber)")}
        onClick={() => onSort(group.id)}
        disabled={count < 2}
      >
        A↓Z
      </button>
      <button
        type="button"
        className="group-edit"
        title={t('Replace or duplicate this group — swap channels to another quality or provider')}
        onClick={() => onDuplicateVariant(group)}
        disabled={count === 0}
      >
        ⎘±
      </button>
      {onCleanNames && (
        <button
          type="button"
          className="group-edit"
          title={t('Strip prefixes/suffixes from the channel names in this group')}
          onClick={() => onCleanNames(group)}
          disabled={count === 0}
        >
          ✂
        </button>
      )}
      {confirmEmpty ? (
        <>
          <button
            type="button"
            className="group-edit danger"
            title={t('Remove all channels from this group (keeps the group)')}
            onClick={() => {
              onClear(group.id)
              setConfirmEmpty(false)
            }}
          >
            {t('Confirm empty')}
          </button>
          <button type="button" className="group-edit" onClick={() => setConfirmEmpty(false)}>
            {t('Cancel')}
          </button>
        </>
      ) : (
        <button
          type="button"
          className="group-edit"
          title={t('Empty group (remove all its channels, keep the group)')}
          onClick={() => setConfirmEmpty(true)}
          disabled={count === 0}
        >
          🧹
        </button>
      )}
      <button
        type="button"
        className="group-edit danger"
        title={t('Delete group (its channels move to Upstream group)')}
        onClick={() => onDelete(group.id)}
      >
        🗑
      </button>
    </h4>
  )
}

interface DragProps {
  isDragging: boolean
  /** This row is the current drop target (the dragged item will land before it). */
  isOver: boolean
  // Pointer Events (mouse + touch). The grip captures the pointer on down; move
  // hit-tests the row under the finger; up performs the reorder.
  onDown: (e: React.PointerEvent) => void
  onMove: (e: React.PointerEvent) => void
  onUp: (e: React.PointerEvent) => void
}

interface ItemRowProps {
  item: CustomItem
  sourceName: string
  groups: CustomGroup[]
  onSave: (patch: Partial<CustomItem> & { id: number }) => void
  onDelete: (id: number) => void
  /** Open the "measure quality" dialog for this channel. */
  onProbe?: (item: CustomItem) => void
  /** When set, the row is a drag source/target for channel-number reordering. */
  drag?: DragProps
}

function ItemRow({ item, sourceName, groups, onSave, onDelete, onProbe, drag }: ItemRowProps) {
  const t = useT()
  const [displayName, setDisplayName] = useState(item.displayName ?? '')
  const [logoOverride, setLogoOverride] = useState(item.logoOverride ?? '')
  const [tvgIdOverride, setTvgIdOverride] = useState(item.tvgIdOverride ?? '')
  const [channelNumber, setChannelNumber] = useState(String(item.channelNumber))
  const [groupId, setGroupId] = useState(item.customGroupId)

  const dirty =
    displayName !== (item.displayName ?? '') ||
    logoOverride !== (item.logoOverride ?? '') ||
    tvgIdOverride !== (item.tvgIdOverride ?? '') ||
    channelNumber !== String(item.channelNumber) ||
    groupId !== item.customGroupId

  function save() {
    onSave({
      id: item.id,
      displayName: displayName.trim(), // '' = follow the provider name again
      logoOverride: logoOverride.trim(), // '' = provider logo again
      tvgIdOverride: tvgIdOverride.trim(),
      channelNumber: Number(channelNumber) || 0,
      customGroupId: groupId,
    })
  }

  return (
    <li
      data-item-id={item.id}
      className={
        'item-row' +
        (drag?.isDragging ? ' dragging' : '') +
        (drag?.isOver ? ' drop-target' : '')
      }
    >
      {drag && (
        // only the grip starts a drag, so the text inputs stay editable; touch-action
        // none lets a touch-drag from the grip work without scrolling the page
        <span
          className="drag-grip"
          style={{ touchAction: 'none' }}
          onPointerDown={drag.onDown}
          onPointerMove={drag.onMove}
          onPointerUp={drag.onUp}
          title={t('Drag to reorder')}
          aria-label={t('Reorder')}
        >
          ⠿
        </span>
      )}
      <input
        className="cn"
        type="number"
        value={channelNumber}
        onChange={(e) => setChannelNumber(e.target.value)}
        title={t('Channel number')}
      />
      <span className="dn-wrap">
        <input
          className="dn"
          placeholder={item.streamName?.trim() || t('Display name')}
          title={item.streamName ? t('Upstream: {name}').replace('{name}', item.streamName) : undefined}
          value={displayName}
          onChange={(e) => setDisplayName(e.target.value)}
        />
        {/* the original provider name (with its prefix/suffix) whenever the list
            shows a different (stripped or renamed) name */}
        {item.streamName?.trim() &&
          (item.displayName ?? '').trim() !== '' &&
          (item.displayName ?? '').trim() !== item.streamName.trim() && (
            <span className="item-orig" title={t('Original name: {name}').replace('{name}', item.streamName)}>
              {item.streamName}
            </span>
          )}
      </span>
      <span
        className={sourceName ? 'badge item-src' : 'badge item-src gone'}
        title={sourceName ? t('Source: {name}').replace('{name}', sourceName) : t('Upstream channel no longer exists')}
      >
        {sourceName || '?'}
      </span>
      <ArchiveBadge days={item.streamArchiveDays} />
      <input
        className="logo"
        placeholder={t('Logo override URL')}
        value={logoOverride}
        onChange={(e) => setLogoOverride(e.target.value)}
      />
      <input
        className="tvg"
        list="iptv-tvgids"
        placeholder={item.streamTvgId?.trim() || t('tvg-id (EPG)')}
        title={
          item.streamTvgId
            ? t('Upstream tvg-id: {id} — empty = use that one').replace('{id}', item.streamTvgId)
            : t('No upstream tvg-id — pick one for the guide/Plex')
        }
        value={tvgIdOverride}
        onChange={(e) => setTvgIdOverride(e.target.value)}
      />
      <select value={groupId} onChange={(e) => setGroupId(Number(e.target.value))}>
        <option value={0}>{t('Upstream group')}</option>
        {groups.map((g) => (
          <option key={g.id} value={g.id}>
            {g.isFavorite ? '★ ' : ''}
            {g.name}
          </option>
        ))}
      </select>
      {onProbe && item.contentType === 'live' && !!item.streamSourceId && (
        <button
          type="button"
          className="probe-btn"
          title={t('Measure quality: all variants of this channel')}
          aria-label={t('Measure quality')}
          onClick={() => onProbe(item)}
        >
          📊
        </button>
      )}
      <button onClick={save} disabled={!dirty}>
        {t('Save')}
      </button>
      <button
        type="button"
        className="item-del danger"
        title={t('Remove channel from the list')}
        aria-label={t('Remove channel')}
        onClick={() => onDelete(item.id)}
      >
        🗑
      </button>
    </li>
  )
}
