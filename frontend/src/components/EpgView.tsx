import { useEffect, useMemo, useRef, useState, type SyntheticEvent } from 'react'
import { api } from '../api/client'
import type { CustomItem, CustomList, EpgProgramme, StreamItem } from '../types'
import { useDebounced } from '../hooks/useDebounced'
import { useT } from '../i18n'

/** A provider logo that 404s shows a broken-image icon; hide it instead. */
const hideBrokenImg = (e: SyntheticEvent<HTMLImageElement>) => {
  e.currentTarget.style.display = 'none'
}

interface Props {
  /** Curated lists (shared from App). */
  lists: CustomList[]
  /** The list currently active in the workbench, used as the default for OWN mode. */
  activeListId: number | null
}

type Mode = 'source' | 'own'

/** Local time HH:MM for an ISO-8601 UTC string. */
function fmtTime(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return '--:--'
  return d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
}

/** Local short date for grouping/labels. */
function fmtDate(iso: string): string {
  const d = new Date(iso)
  if (Number.isNaN(d.getTime())) return ''
  return d.toLocaleDateString(undefined, { weekday: 'short', day: '2-digit', month: 'short' })
}

/** Hour-tick label for the timeline; shows the date when the day changes from the
 *  previous tick. Comparing consecutive ticks (rather than testing getHours()===0)
 *  also works in sub-hour-offset zones (UTC+5:30 etc.) where no tick lands on the
 *  local midnight hour. */
function fmtTick(ms: number, prevMs: number | null): string {
  const d = new Date(ms)
  const hh = d.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' })
  const dayChanged = prevMs === null || new Date(prevMs).toDateString() !== d.toDateString()
  return dayChanged ? `${fmtDate(d.toISOString())} ${hh}` : hh
}

function isNow(p: EpgProgramme, now: number): boolean {
  const start = new Date(p.startUtc).getTime()
  const stop = new Date(p.stopUtc).getTime()
  return start <= now && now < stop
}

function byStart(a: EpgProgramme, b: EpgProgramme): number {
  return new Date(a.startUtc).getTime() - new Date(b.startUtc).getTime()
}

export function EpgView({ lists, activeListId }: Props) {
  const t = useT()
  const [mode, setMode] = useState<Mode>('own')
  // Re-render roughly every minute so the "on now" highlight stays current.
  const [now, setNow] = useState(() => Date.now())
  useEffect(() => {
    const t = setInterval(() => setNow(Date.now()), 60_000)
    return () => clearInterval(t)
  }, [])

  return (
    <section className="panel epg">
      <header className="panel-head">
        <h2>{t('EPG')}</h2>
        <div className="segmented">
          <button
            className={mode === 'own' ? 'seg active' : 'seg'}
            onClick={() => setMode('own')}
          >
            {t('Own list')}
          </button>
          <button
            className={mode === 'source' ? 'seg active' : 'seg'}
            onClick={() => setMode('source')}
          >
            {t('Source')}
          </button>
        </div>
      </header>

      {mode === 'source' ? (
        <SourceEpg now={now} />
      ) : (
        <OwnEpg lists={lists} activeListId={activeListId} now={now} />
      )}
    </section>
  )
}

/** SOURCE mode: pick a live channel that has a tvgId, then show its source EPG. */
function SourceEpg({ now }: { now: number }) {
  const t = useT()
  const [search, setSearch] = useState('')
  const debSearch = useDebounced(search, 300)

  const [channels, setChannels] = useState<StreamItem[]>([])
  const [chLoading, setChLoading] = useState(false)
  const [chError, setChError] = useState<string | null>(null)

  const [selected, setSelected] = useState<StreamItem | null>(null)
  const [programmes, setProgrammes] = useState<EpgProgramme[]>([])
  const [epgLoading, setEpgLoading] = useState(false)
  const [epgError, setEpgError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    setChLoading(true)
    setChError(null)
    api
      .streams({ search: debSearch.trim() || undefined, type: 'live' })
      .then((rows) => {
        if (cancelled) return
        // Only channels that carry a tvgId can have an EPG.
        setChannels(rows.filter((r) => !!r.tvgId))
      })
      .catch((e) => {
        if (!cancelled) setChError((e as Error).message)
      })
      .finally(() => {
        if (!cancelled) setChLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [debSearch])

  useEffect(() => {
    if (!selected?.tvgId) {
      setProgrammes([])
      return
    }
    let cancelled = false
    const tvgId = selected.tvgId
    setEpgLoading(true)
    setEpgError(null)
    api
      .epg(tvgId)
      .then((rows) => {
        if (!cancelled) setProgrammes([...rows].sort(byStart))
      })
      .catch((e) => {
        if (!cancelled) setEpgError((e as Error).message)
      })
      .finally(() => {
        if (!cancelled) setEpgLoading(false)
      })
    return () => {
      cancelled = true
    }
  }, [selected])

  return (
    <div className="epg-body">
      <div className="epg-picker">
        <input
          placeholder={t('Search live channels…')}
          value={search}
          onChange={(e) => setSearch(e.target.value)}
        />
        {chError && <p className="error">{chError}</p>}
        <ul className="epg-channels">
          {chLoading && <li className="muted">{t('Loading…')}</li>}
          {!chLoading && channels.length === 0 && (
            <li className="muted">{t('No channels with a tvg-id match.')}</li>
          )}
          {channels.map((c) => (
            <li
              key={c.id}
              className={selected?.id === c.id ? 'epg-channel selected' : 'epg-channel'}
              onClick={() => setSelected(c)}
            >
              {c.logo && <img className="ch-logo" src={c.logo} alt="" onError={hideBrokenImg} />}
              <span className="ch-name">{c.name}</span>
              <span className="muted ch-tvg">{c.tvgId}</span>
            </li>
          ))}
        </ul>
      </div>

      <div className="epg-schedule">
        {!selected ? (
          <p className="muted center">{t('Pick a channel to see its guide.')}</p>
        ) : epgLoading ? (
          <p className="muted">{t('Loading guide…')}</p>
        ) : epgError ? (
          <p className="error">{epgError}</p>
        ) : (
          <ScheduleList title={selected.name} programmes={programmes} now={now} />
        )}
      </div>
    </div>
  )
}

/** OWN mode: curated EPG for the active list, one lane per channel. */
function OwnEpg({
  lists,
  activeListId,
  now,
}: {
  lists: CustomList[]
  activeListId: number | null
  now: number
}) {
  const t = useT()
  const [listId, setListId] = useState<number | ''>(activeListId ?? '')
  const [programmes, setProgrammes] = useState<EpgProgramme[]>([])
  const [items, setItems] = useState<CustomItem[]>([])
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [reloadKey, setReloadKey] = useState(0)
  const [epgMsg, setEpgMsg] = useState<string | null>(null)
  // the post-refresh poll timer — tracked so we can stop it on unmount and never
  // run two at once (a second "Update EPG" click would otherwise overlap)
  const pollRef = useRef<ReturnType<typeof setInterval> | null>(null)
  useEffect(() => () => { if (pollRef.current) clearInterval(pollRef.current) }, [])

  // Seed the EPG-view list from the workbench's active list, but only while the
  // user hasn't picked one here yet — otherwise a later activeListId change would
  // clobber their explicit choice in this view's own list selector.
  useEffect(() => {
    if (activeListId != null) setListId((cur) => (cur === '' ? activeListId : cur))
  }, [activeListId])

  useEffect(() => {
    if (listId === '') {
      setProgrammes([])
      return
    }
    let cancelled = false
    setLoading(true)
    setError(null)
    api
      .listEpg(listId)
      .then((rows) => {
        if (!cancelled) setProgrammes(rows)
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
  }, [listId, reloadKey])

  // Channel logo + display name per (effective) tvg-id, taken from the list items,
  // so the guide grid can show the channel — logo + name — instead of a bare tvg-id.
  useEffect(() => {
    if (listId === '') {
      setItems([])
      return
    }
    let cancelled = false
    api
      .listItems(listId)
      .then((rows) => {
        if (!cancelled) setItems(rows)
      })
      .catch(() => {
        /* labels just fall back to the tvg-id */
      })
    return () => {
      cancelled = true
    }
  }, [listId])

  const chInfo = useMemo(() => {
    const m = new Map<string, { name: string; logo: string }>()
    for (const it of items) {
      const tvg = (it.tvgIdOverride || it.streamTvgId || '').trim()
      if (!tvg || m.has(tvg)) continue
      m.set(tvg, {
        name: it.displayName || it.streamName || tvg,
        logo: it.logoOverride || it.streamLogo || '',
      })
    }
    return m
  }, [items])

  // Trigger a server-side EPG re-fetch for the channels now on the list, then
  // reload the view a few times as the (possibly large) guide comes in.
  async function updateEpg() {
    setEpgMsg(t('Updating EPG… (may take a while)'))
    try {
      await api.refreshEpg()
    } catch (e) {
      setError((e as Error).message)
      return
    }
    let n = 0
    if (pollRef.current) clearInterval(pollRef.current) // never overlap two polls
    pollRef.current = setInterval(() => {
      n += 1
      setReloadKey((k) => k + 1)
      if (n >= 5) {
        if (pollRef.current) clearInterval(pollRef.current)
        pollRef.current = null
        setEpgMsg(null)
      }
    }, 3000)
  }

  // Group programmes into one lane per channelTvgId, each sorted by start.
  const lanes = useMemo(() => {
    const byChannel = new Map<string, EpgProgramme[]>()
    for (const p of programmes) {
      const arr = byChannel.get(p.channelTvgId)
      if (arr) arr.push(p)
      else byChannel.set(p.channelTvgId, [p])
    }
    return [...byChannel.entries()]
      .map(([channelTvgId, ps]) => ({ channelTvgId, programmes: [...ps].sort(byStart) }))
      .sort((a, b) => a.channelTvgId.localeCompare(b.channelTvgId, undefined, { sensitivity: 'base' }))
  }, [programmes])

  return (
    <div className="epg-body own">
      <div className="epg-picker compact">
        <label className="inline">
          {t('List')}
          <select
            value={listId}
            onChange={(e) => setListId(e.target.value === '' ? '' : Number(e.target.value))}
          >
            <option value="">{t('Select list…')}</option>
            {lists.map((l) => (
              <option key={l.id} value={l.id}>
                {l.name}
              </option>
            ))}
          </select>
        </label>
        <span className="muted">{t('{n} channels').replace('{n}', String(lanes.length))}</span>
        <button type="button" onClick={updateEpg} disabled={listId === ''} title={t('Re-fetch EPG for the channels now on the list')}>
          {t('⟳ Update EPG')}
        </button>
        <button type="button" onClick={() => setReloadKey((k) => k + 1)} disabled={listId === ''}>
          {t('Reload')}
        </button>
        {epgMsg && <span className="muted">{epgMsg}</span>}
      </div>

      {listId === '' ? (
        <p className="muted center">{t('Select a list to see its curated guide.')}</p>
      ) : loading ? (
        <p className="muted">{t('Loading guide…')}</p>
      ) : error ? (
        <p className="error">{error}</p>
      ) : lanes.length === 0 ? (
        <p className="muted center">{t('No programmes for this list.')}</p>
      ) : (
        <EpgGrid lanes={lanes} now={now} channelInfo={chInfo} />
      )}
    </div>
  )
}

const HOUR_MS = 3_600_000
const PX_PER_HOUR = 170 // timeline scale
const LABEL_W = 150 // frozen channel column width

/** A real TV-guide grid: channels as rows, time on the horizontal axis,
 *  programme blocks sized by duration, a live "now" line. Frozen header row
 *  + channel column; the timeline scrolls. */
function EpgGrid({
  lanes,
  now,
  channelInfo,
}: {
  lanes: { channelTvgId: string; programmes: EpgProgramme[] }[]
  now: number
  channelInfo: Map<string, { name: string; logo: string }>
}) {
  const t = useT()
  const { windowStart, totalWidth, ticks, xOf } = useMemo(() => {
    const starts: number[] = []
    const stops: number[] = []
    for (const l of lanes)
      for (const p of l.programmes) {
        starts.push(new Date(p.startUtc).getTime())
        stops.push(new Date(p.stopUtc).getTime())
      }
    const startHour = Math.floor(now / HOUR_MS) * HOUR_MS
    const minData = starts.length ? Math.min(...starts) : startHour
    const maxData = stops.length ? Math.max(...stops) : startHour + 12 * HOUR_MS
    // anchored on NOW: show the past the guide has (catch-up), at most a day back,
    // and up to two days ahead. Whole hours, so the ticks read 07:00, 08:00 …
    const wStart = Math.max(
      Math.floor(Math.min(startHour - HOUR_MS, minData) / HOUR_MS) * HOUR_MS,
      startHour - 24 * HOUR_MS,
    )
    const wEnd = Math.min(Math.max(maxData, startHour + 12 * HOUR_MS), startHour + 48 * HOUR_MS)
    const x = (ms: number) => ((ms - wStart) / HOUR_MS) * PX_PER_HOUR
    const t: number[] = []
    for (let h = wStart; h <= wEnd; h += HOUR_MS) t.push(h)
    return { windowStart: wStart, totalWidth: x(wEnd), ticks: t, xOf: x }
  }, [lanes, now])

  const nowX = now >= windowStart && now <= windowStart + (totalWidth / PX_PER_HOUR) * HOUR_MS ? xOf(now) : null
  const rowWidth = LABEL_W + totalWidth

  // open at "now" (an hour before it), not at the start of the window; once per
  // data load, so the minute tick doesn't yank the view back while you scroll
  const gridRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const el = gridRef.current
    if (el && nowX !== null) el.scrollLeft = Math.max(0, nowX - PX_PER_HOUR)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lanes, windowStart])

  return (
    <div className="epg-grid" ref={gridRef}>
      <div className="epg-grid-head" style={{ width: rowWidth }}>
        <div className="epg-corner" style={{ width: LABEL_W }}>
          {t('Channel')}
        </div>
        <div className="epg-timeline-head" style={{ width: totalWidth }}>
          {ticks.map((t, i) => (
            <div key={t} className="epg-tick" style={{ left: xOf(t) }}>
              {fmtTick(t, i > 0 ? ticks[i - 1] : null)}
            </div>
          ))}
        </div>
      </div>

      {lanes.map((lane) => (
        <div className="epg-row" key={lane.channelTvgId} style={{ width: rowWidth }}>
          <div className="epg-row-label" style={{ width: LABEL_W }} title={lane.channelTvgId}>
            {(() => {
              const info = channelInfo.get(lane.channelTvgId)
              return (
                <>
                  {info?.logo && <img className="epg-row-logo" src={info.logo} alt="" onError={hideBrokenImg} />}
                  <span className="epg-row-name">{info?.name || lane.channelTvgId}</span>
                </>
              )
            })()}
          </div>
          <div className="epg-track" style={{ width: totalWidth }}>
            {nowX !== null && <div className="epg-now-line" style={{ left: nowX }} />}
            {lane.programmes.map((p, pi) => {
              const left = Math.max(0, xOf(new Date(p.startUtc).getTime()))
              const right = Math.min(totalWidth, xOf(new Date(p.stopUtc).getTime()))
              const width = right - left
              if (width <= 0) return null
              const live = isNow(p, now)
              return (
                <div
                  key={`${p.startUtc}|${p.title}|${pi}`}
                  className={live ? 'epg-prog-block now' : 'epg-prog-block'}
                  style={{ left, width }}
                  title={`${fmtTime(p.startUtc)}–${fmtTime(p.stopUtc)}  ${p.title}${
                    p.description ? `\n\n${p.description}` : ''
                  }`}
                >
                  <span className="epg-prog-time">
                    {fmtTime(p.startUtc)}
                    {live && t(' · NOW')}
                  </span>
                  <span className="epg-prog-title">{p.title}</span>
                </div>
              )
            })}
          </div>
        </div>
      ))}
    </div>
  )
}

/** Vertical schedule for one channel: start–stop + title; click to reveal description. */
function ScheduleList({
  title,
  programmes,
  now,
}: {
  title: string
  programmes: EpgProgramme[]
  now: number
}) {
  const t = useT()
  const [openKey, setOpenKey] = useState<string | null>(null)

  return (
    <div className="schedule">
      <h3 className="schedule-head">{title}</h3>
      {programmes.length === 0 ? (
        <p className="muted">{t('No programmes.')}</p>
      ) : (
        <ul className="prog-list">
          {programmes.map((p, pi) => {
            const key = `${p.startUtc}|${p.title}|${pi}`
            const live = isNow(p, now)
            const open = openKey === key
            return (
              <li
                key={key}
                className={live ? 'prog now' : 'prog'}
                onClick={() => setOpenKey(open ? null : key)}
              >
                <div className="prog-head">
                  <span className="prog-time">
                    {fmtTime(p.startUtc)}–{fmtTime(p.stopUtc)}
                  </span>
                  <span className="prog-title">{p.title}</span>
                  {live && <span className="badge now-badge">{t('NOW')}</span>}
                  {p.category && <span className="badge cat">{p.category}</span>}
                </div>
                {open && p.description && <p className="prog-desc">{p.description}</p>}
                {open && <span className="prog-date muted">{fmtDate(p.startUtc)}</span>}
              </li>
            )
          })}
        </ul>
      )}
    </div>
  )
}
