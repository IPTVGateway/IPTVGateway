// Mirrors the Delphi core models (IPTV.Model.*). Keep in sync with the backend.

export type SourceKind = 'xtream' | 'm3u' | 'stalker'
export type ContentType = 'live' | 'movie' | 'series' | 'radio'

export interface Source {
  id: number
  name: string
  kind: SourceKind
  url: string
  username?: string
  password?: string
  epgUrl?: string
  userAgent?: string // per-provider User-Agent override (empty => built-in default)
  referer?: string   // per-provider Referer header (some portals require it)
  forceHls?: boolean // live always handed to the box as .m3u8 (provider drops .ts)
  preferOwnEpg?: boolean // this provider's own guide before the extra EPG source
  enabled: boolean
  contentTypes: ContentType[] // which types to ingest/offer
  includeFilters?: string[]   // keep only names matching a prefix/suffix (empty => all)
  excludeFilters?: string[]   // drop names matching a prefix/suffix
  stripPrefixes?: string[]    // leading tokens (e.g. "NL") removed from a channel name when added to a list
  stripSuffixes?: string[]    // trailing tokens (e.g. "(S)") removed likewise
  lastRefreshUtc?: string
  // provider account (Xtream user_info), read-only, filled on refresh
  accountStatus?: string // '' = unknown
  expiresUtc?: string // '' = no end date (when accountStatus is set)
  maxConnections?: number
}

/** Live progress of a source ingest (busy/done/error + counts). */
export interface IngestStatus {
  sourceId: number
  running: boolean
  startedUtc: string
  finishedUtc: string
  streams: number
  categories: number
  programmes: number
  error: string
}

/** A leading name-prefix discovered in a source's streams, with its frequency. */
export interface PrefixCount {
  prefix: string
  count: number
}

export interface Category {
  id: number
  sourceId: number
  upstreamId: string // pass as ?category= to list this group's streams
  contentType: ContentType
  name: string
  isNew: boolean
  seenAtUtc?: string
}

export interface StreamItem {
  id: number
  sourceId: number
  contentType: ContentType
  name: string
  logo?: string
  groupTitle?: string
  tvgId?: string
  /** provider catch-up window in days (Xtream tv_archive), 0 = none */
  archiveDays?: number
  isNew: boolean
  seenAtUtc?: string
}

export interface CustomGroup {
  id: number
  listId: number
  name: string
  contentType: ContentType
  isFavorite: boolean
  sortOrder?: number // manual drag order (0/undefined = unset → A→Z); favorites still first
}

export interface CustomItem {
  id: number
  listId: number
  streamItemId: number
  customGroupId: number // 0 => upstream group
  contentType: ContentType
  displayName?: string
  logoOverride?: string
  tvgIdOverride?: string // override the guide id (EPG/Plex matching); empty => upstream tvg-id
  channelNumber: number
  // read-only upstream values resolved by the backend (label fallback in the UI)
  streamName?: string
  streamLogo?: string
  streamTvgId?: string
  streamSourceId?: number // 0/undefined = upstream stream gone
  streamArchiveDays?: number // provider catch-up window in days, 0 = none
}

/** One channel in a group with its proposed quality-variant replacement, for
 *  "duplicate this group at another quality". matched=false / candidateStreamId=0
 *  when no variant of the target quality exists (the channel is flagged, not added). */
export interface VariantMatch {
  itemId: number
  streamId: number
  name: string // current channel name (upstream)
  quality: string // current detected quality ('' if none)
  candidateStreamId: number // the target-quality variant (0 = none)
  candidateName: string
  matched: boolean
  alreadyInList: boolean // candidate already on this list — can't be re-added
}

/** One quality variant of a single channel (the quality probe's rows). */
export interface StreamVariant {
  streamId: number
  sourceId: number
  name: string // upstream name
  quality: string // canonical quality word ('' if none)
  tvgId: string
  groupTitle: string
  isSelf: boolean // the channel the search started from
  matchedBy: 'self' | 'name' | 'tvg'
  onList: boolean // already on the given list
}

/** What a few seconds of a stream really contain (POST …/probe). */
export interface ProbeResult {
  streamId: number
  ok: boolean
  error: string
  container: string // 'mpegts' | 'hls' | 'hls-fmp4' | content type
  videoCodec: string
  profile: string
  width: number
  height: number
  fps: number
  interlaced: boolean
  bitDepth: number
  audio: { codec: string; language: string }[]
  bitrateKbps: number
  mediaSeconds: number
  wallSeconds: number
  realtime: number // media s / wall s; < 1 = can't keep up
  firstByteMs: number
  redirects: number
  bytes: number
}

/** A guide id (tvg-id) known in the catalog, for the per-channel tvg-id picker. */
export interface TvgIdInfo {
  tvgId: string
  name: string
}

export interface CustomList {
  id: number
  name: string
  outputUsername: string
  outputPassword: string
  enabled: boolean
  /** id of the list this one mirrors (0/undefined = a normal list with its own channels) */
  mirrorOfListId?: number
}

/** A mirror bouquet's own provider account for one source ('' = the source's value). */
export interface MirrorCredential {
  sourceId: number
  url: string
  username: string
  password: string
}

/** Runtime settings (subset of config.json) exposed via /api/config. */
export interface AppConfig {
  refreshHour: number
  refreshMinute: number
  epgMaxDays?: number // cap the served guide to N days ahead (0 = unlimited)
  proxyStreams: boolean
  proxyPort: number
  streamFailover?: boolean // relay falls back to the same channel from another source
  // Plex Live TV: two tuner surfaces, each on/off + its own proxy choice
  plexM3uEnabled?: boolean
  plexM3uProxy?: boolean
  plexHdhrEnabled?: boolean
  plexHdhrProxy?: boolean
  plexTunerCount?: number
  plexListId?: number // bouquet served to Plex/Jellyfin; 0 = first enabled
  plexServerUrl?: string // optional Plex server for the "rescan Plex" button
  plexToken?: string     // X-Plex-Token
  // media servers: global group filter + base URL (now editable) + dummy EPG
  visibleGroups?: string[] // only these group-titles are published (empty = all)
  extraEpgUrls?: string[]  // extra (third-party) XMLTV guides, first = highest priority
  mediaAllowedClients?: string[] // Plex/HDHomeRun endpoints: allowed IPs or "a.b.c." prefixes; empty = all
  publicBaseUrl: string    // base URL boxes use; empty => request Host header
  dummyEpgEnabled?: boolean
  dummyEpgBlockMinutes?: number
  dummyEpgHoursBack?: number
  dummyEpgHoursAhead?: number
  nameShowGroup?: boolean // prefix channel names with their group on the Plex surfaces
  nameShowNumber?: boolean // prefix a zero-padded sort number so Plex keeps bouquet order
  nameShowSource?: boolean // prefix a per-provider letter (A/B/…) so Plex groups by source
  idSortPrefix?: boolean // prefix a sort number in the channel-id so Plex sorts by bouquet order
  // read-only context
  httpPort: number
  useHttps: boolean
  plexDeviceId?: string
}

/** A selectable output group-title with how many channels carry it. */
export interface MediaGroup {
  name: string
  channels: number
}

/** Status of the current global group filter. */
export interface MediaStatus {
  channels: number // channels published after filtering
  realEpg: number  // of those, how many have real guide data
  dummyEpg: number // …and how many get dummy filler
}

export interface EpgProgramme {
  channelTvgId: string
  startUtc: string // ISO-8601 UTC
  stopUtc: string
  title: string
  description: string
  category: string
}
