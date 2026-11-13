// Thin typed wrapper over the admin REST API. Calls go to /api/* which Vite
// proxies to the Delphi backend in dev (see vite.config.ts).

import type {
  Source,
  StreamItem,
  Category,
  CustomList,
  CustomGroup,
  CustomItem,
  ContentType,
  EpgProgramme,
  PrefixCount,
  TvgIdInfo,
  VariantMatch,
  StreamVariant,
  ProbeResult,
  AppConfig,
  IngestStatus,
  MediaGroup,
  MediaStatus,
} from '../types'
import { DEFAULT_PROBE_SECONDS } from '../lib/constants'

// ── admin password (optional) ───────────────────────────────────────────────
// When the backend has an admin password set, every /api/* call must carry it.
// We keep it in localStorage and send it as a header (and, for plain <a download>
// links that can't set headers, as a ?pw= query param).
// every admin endpoint lives under this path (Vite proxies it to the backend in dev)
const API_BASE = '/api'
const PW_KEY = 'iptv.admin.pw'
const ADMIN_PASSWORD_HEADER = 'X-Admin-Password'
// longest backend error detail we put into an Error message
const MAX_ERROR_DETAIL = 300
export const adminAuth = {
  get: () => localStorage.getItem(PW_KEY) ?? '',
  set: (v: string) => localStorage.setItem(PW_KEY, v),
  clear: () => localStorage.removeItem(PW_KEY),
}

let onUnauthorized: (() => void) | null = null
/** Register a callback fired whenever an /api call returns 401 (drop to login). */
export function setUnauthorizedHandler(fn: (() => void) | null) {
  onUnauthorized = fn
}

export class UnauthorizedError extends Error {
  constructor() {
    super('401 Unauthorized')
    this.name = 'UnauthorizedError'
  }
}

const HTTP_UNAUTHORIZED = 401
const CLIENT_HEADER = 'X-IPTV-Client'
const CLIENT_HEADER_VALUE = 'web'

async function http<T>(path: string, init?: RequestInit): Promise<T> {
  const pw = adminAuth.get()
  const headers: Record<string, string> = {
    'Content-Type': 'application/json',
    // CSRF guard: the backend refuses state-changing /api calls without it (another
    // site can't add a custom header without a CORS preflight the backend never approves)
    [CLIENT_HEADER]: CLIENT_HEADER_VALUE,
    ...((init?.headers as Record<string, string>) ?? {}),
  }
  if (pw) headers[ADMIN_PASSWORD_HEADER] = pw
  const res = await fetch(`${API_BASE}${path}`, { ...init, headers })
  // Read once as text so we tolerate empty bodies (void endpoints) and
  // non-JSON error pages (e.g. a 500 HTML page) without throwing a parse error.
  const text = await res.text()
  if (res.status === HTTP_UNAUTHORIZED) {
    onUnauthorized?.()
    throw new UnauthorizedError()
  }
  if (!res.ok) {
    const detail = text.trim().replace(/<[^>]*>/g, ' ').replace(/\s+/g, ' ').trim().slice(0, MAX_ERROR_DETAIL)
    throw new Error(`${res.status} ${detail || res.statusText}`)
  }
  if (!text) return undefined as T
  try {
    return JSON.parse(text) as T
  } catch {
    return undefined as T // non-JSON success body (shouldn't happen, but don't crash)
  }
}

// download links can't send headers — pass the password as a query param instead
function pwQuery(): string {
  const pw = adminAuth.get()
  return pw ? `?pw=${encodeURIComponent(pw)}` : ''
}

/** A portable settings export (config + sources + lists with their groups). */
export interface SettingsBundle {
  version?: number
  config?: Partial<AppConfig>
  sources?: Partial<Source>[]
  lists?: (Partial<CustomList> & { groups?: Partial<CustomGroup>[] })[]
}

/** One line of the service log (GET /api/logs). */
export interface LogLine {
  seq: number
  t: string // ISO-8601 UTC
  text: string
}

export interface CatalogQuery {
  sourceId?: number
  type?: ContentType
  onlyNew?: boolean
  search?: string // name contains
  prefix?: string // name starts-with, e.g. "NL:"
  category?: string // upstream category/group id (drill into one group)
  inCategory?: boolean // drilled: filter on `category` even when it is ''
  limit?: number // page size (streams only)
  offset?: number // page offset
}

function qs(q: CatalogQuery): string {
  const p = new URLSearchParams()
  if (q.sourceId) p.set('sourceId', String(q.sourceId))
  if (q.type) p.set('type', q.type)
  if (q.onlyNew) p.set('onlyNew', '1')
  if (q.search) p.set('search', q.search)
  if (q.prefix) p.set('prefix', q.prefix)
  if (q.category) p.set('category', q.category)
  if (q.inCategory) p.set('inCategory', '1')
  if (q.limit) p.set('limit', String(q.limit))
  if (q.offset) p.set('offset', String(q.offset))
  const s = p.toString()
  return s ? `?${s}` : ''
}

export const api = {
  health: () => http<{ status: string; version?: string; hasApp?: boolean }>('/health'),
  // the in-memory service log: lines after `since` (a seq), oldest first
  logs: (since = 0) => http<{ next: number; lines: LogLine[] }>(`/logs?since=${since}`),

  // sources
  listSources: () => http<Source[]>('/sources'),
  saveSource: (s: Partial<Source>) => http<Source>('/sources', { method: 'POST', body: JSON.stringify(s) }),
  deleteSource: (id: number) => http<void>(`/sources/${id}`, { method: 'DELETE' }),
  refreshSource: (id: number) => http<void>(`/sources/${id}/refresh`, { method: 'POST' }),
  refreshAll: () => http<void>('/refresh', { method: 'POST' }),
  // re-apply every source's strip-prefixes to all channels already on lists
  restripPrefixes: () => http<{ updated: number }>('/restrip-prefixes', { method: 'POST' }),
  // live ingest progress per source (busy/done/error + counts)
  refreshStatus: () => http<IngestStatus[]>('/refresh/status'),
  // re-fetch EPG for the channels currently on a list (no full catalog refresh)
  refreshEpg: () => http<{ started: boolean }>('/epg/refresh', { method: 'POST' }),
  // distinct leading name-prefixes (e.g. "NL|") found in this source's streams,
  // most common first — powers the filter-prefix picker
  sourcePrefixes: (id: number) => http<PrefixCount[]>(`/sources/${id}/prefixes`),
  // distinct guide ids (tvg-id) in the catalog, for the per-channel tvg-id picker
  tvgIds: () => http<TvgIdInfo[]>('/tvg-ids'),

  // add-on UI languages dropped into the mounted lang/ folder (en/nl are built in).
  // list them ({code,name}) and fetch one's translation dictionary.
  languages: () => http<{ code: string; name: string }[]>('/languages'),
  language: (code: string) => http<Record<string, string>>(`/languages/${encodeURIComponent(code)}`),

  // catalog + change tracking
  categories: (q: CatalogQuery = {}) => http<Category[]>(`/catalog/categories${qs(q)}`),
  streams: (q: CatalogQuery = {}) => http<StreamItem[]>(`/catalog/streams${qs(q)}`),
  countStreams: (q: CatalogQuery = {}) => http<{ count: number }>(`/catalog/streams/count${qs(q)}`),
  markCategoriesSeen: (ids: number[]) =>
    http<void>('/catalog/categories/seen', { method: 'POST', body: JSON.stringify({ ids }) }),
  markStreamsSeen: (ids: number[]) =>
    http<void>('/catalog/streams/seen', { method: 'POST', body: JSON.stringify({ ids }) }),

  // EPG
  epg: (tvgId: string) => http<EpgProgramme[]>(`/epg?tvgId=${encodeURIComponent(tvgId)}`), // source EPG for one channel
  listEpg: (listId: number) => http<EpgProgramme[]>(`/lists/${listId}/epg`), // curated EPG (chosen channels)

  // settings (config.json)
  getConfig: () => http<AppConfig>('/config'),
  saveConfig: (c: Partial<AppConfig>) =>
    http<AppConfig>('/config', { method: 'POST', body: JSON.stringify(c) }),
  // media servers (Plex/Jellyfin): selectable group-titles + filter status
  mediaGroups: () => http<MediaGroup[]>('/media/groups'),
  mediaStatus: () => http<MediaStatus>('/media/status'),
  // regenerate the HDHomeRun DeviceID (Plex then re-imports as a fresh device)
  resetDeviceId: () => http<{ deviceId: string }>('/media/device-id/reset', { method: 'POST' }),
  // tell the configured Plex server to reload its DVR guide/lineup
  plexRescan: () => http<{ dvrs: number }>('/plex/rescan', { method: 'POST' }),
  // reminder state: is a Plex rescan due, is a tuner enabled, is the API configured
  plexStatus: () => http<{ pending: boolean; enabled: boolean; configured: boolean }>('/plex/status'),

  // portable settings bundle: config + sources + lists + groups (NOT the picked
  // channels). Export returns the JSON object; import replaces the whole config.
  exportSettings: () => http<SettingsBundle>('/export'),
  importSettings: (bundle: SettingsBundle) =>
    http<{ sources: number; lists: number; groups: number }>('/import', {
      method: 'POST',
      body: JSON.stringify(bundle),
    }),

  // output lists / curation
  listLists: () => http<CustomList[]>('/lists'),
  saveList: (l: Partial<CustomList>) =>
    http<CustomList>('/lists', { method: 'POST', body: JSON.stringify(l) }),
  deleteList: (id: number) => http<void>(`/lists/${id}`, { method: 'DELETE' }),
  listGroups: (listId: number) => http<CustomGroup[]>(`/lists/${listId}/groups`),
  saveGroup: (listId: number, g: Partial<CustomGroup>) =>
    http<CustomGroup>(`/lists/${listId}/groups`, { method: 'POST', body: JSON.stringify(g) }),
  deleteGroup: (groupId: number) => http<void>(`/groups/${groupId}`, { method: 'DELETE' }),
  // proposed quality-variant mapping for a group's channels (SD/HD/UHD/4K/…): for
  // each channel, the same channel at the target quality (0 = none found). The
  // client reviews, then creates a new group + bulk-adds the chosen candidates.
  groupVariants: (listId: number, groupId: number, quality: string) =>
    http<VariantMatch[]>(
      `/lists/${listId}/groups/${groupId}/variants?quality=${encodeURIComponent(quality)}`,
    ),
  // proposed mapping to the SAME channels from another provider/source (matched by
  // tvg-id then exact name): "duplicate group from another provider"
  groupProviderVariants: (listId: number, groupId: number, sourceId: number) =>
    http<VariantMatch[]>(
      `/lists/${listId}/groups/${groupId}/provider-variants?sourceId=${sourceId}`,
    ),
  // every quality variant of ONE channel (self included), own source unless allSources
  streamVariants: (streamId: number, opts: { allSources?: boolean; listId?: number } = {}) =>
    http<StreamVariant[]>(
      `/catalog/streams/${streamId}/variants?allSources=${opts.allSources ? 1 : 0}&listId=${opts.listId ?? 0}`,
    ),
  // measure a channel: the backend pulls ~seconds of it from the provider (serialised)
  probeStream: (streamId: number, seconds = DEFAULT_PROBE_SECONDS) =>
    http<ProbeResult>(`/catalog/streams/${streamId}/probe?seconds=${seconds}`, { method: 'POST' }),
  // renumber the whole bouquet across all groups in one transaction (plan computed client-side)
  renumberList: (listId: number, numbers: { itemId: number; channelNumber: number }[]) =>
    http<{ numbered: number }>(`/lists/${listId}/renumber`, {
      method: 'POST',
      body: JSON.stringify({ numbers }),
    }),
  // set the manual drag-order of a list's GROUPS (favorites still pinned on top)
  reorderGroups: (listId: number, groupIds: number[]) =>
    http<{ ordered: number }>(`/lists/${listId}/groups/order`, {
      method: 'POST',
      body: JSON.stringify({ groupIds }),
    }),
  listItems: (listId: number) => http<CustomItem[]>(`/lists/${listId}/items`),
  saveItem: (listId: number, i: Partial<CustomItem>) =>
    http<CustomItem>(`/lists/${listId}/items`, { method: 'POST', body: JSON.stringify(i) }),
  // remove a single channel from the list entirely (one-click "throw out of group")
  deleteItem: (id: number) => http<void>(`/items/${id}`, { method: 'DELETE' }),
  // checkbox multi-select: add many catalog streams to a list (and optional group) at once
  addItems: (listId: number, streamItemIds: number[], customGroupId = 0) =>
    http<{ added: number }>(`/lists/${listId}/items/bulk`, {
      method: 'POST',
      body: JSON.stringify({ streamItemIds, customGroupId }),
    }),
  // swap the stream behind existing items IN PLACE (variant replace inside a group):
  // keeps group, channel number and overrides; skipped when the new stream is already listed
  replaceItems: (listId: number, replacements: { itemId: number; streamId: number }[]) =>
    http<{ replaced: number }>(`/lists/${listId}/items/replace`, {
      method: 'POST',
      body: JSON.stringify({ replacements }),
    }),
  // clean the names of a group's channels after the fact: the sources' strip
  // prefixes/suffixes + one-off extra tokens; dryRun = preview only
  restripGroup: (
    listId: number,
    groupId: number,
    opts: { extraPrefixes?: string[]; extraSuffixes?: string[]; dryRun?: boolean },
  ) =>
    http<{ itemId: number; oldName: string; newName: string; original: string }[]>(
      `/lists/${listId}/groups/${groupId}/restrip`,
      { method: 'POST', body: JSON.stringify(opts) },
    ),
  // remove every item in one group of a list (customGroupId 0 = upstream group)
  clearGroupItems: (listId: number, customGroupId: number) =>
    http<{ removed: number }>(`/lists/${listId}/items/clear`, {
      method: 'POST',
      body: JSON.stringify({ customGroupId }),
    }),
  // remove duplicate channels (same upstream URL) from a list, keeping one
  dedupeList: (listId: number) =>
    http<{ removed: number }>(`/lists/${listId}/dedupe`, { method: 'POST' }),
  // renumber one group's channels A→Z (channel_number = 1,2,3…)
  sortGroup: (listId: number, customGroupId: number) =>
    http<{ sorted: number }>(`/lists/${listId}/groups/sort`, {
      method: 'POST',
      body: JSON.stringify({ customGroupId }),
    }),
  // set channel numbers (1,2,3…) following an explicit drag-and-drop order of item ids
  reorderGroup: (listId: number, customGroupId: number, itemIds: number[]) =>
    http<{ numbered: number }>(`/lists/${listId}/groups/reorder`, {
      method: 'POST',
      body: JSON.stringify({ customGroupId, itemIds }),
    }),

  // download URLs for the curated list (use as <a href download>): the list as
  // M3U_plus (raw upstream URLs) and the curated EPG as XMLTV.
  exportM3uUrl: (listId: number) => `${API_BASE}/lists/${listId}/export.m3u${pwQuery()}`,
  exportXmltvUrl: (listId: number) => `${API_BASE}/lists/${listId}/export.xmltv${pwQuery()}`,
}
