import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../api/client'
import { DEFAULT_PROBE_SECONDS } from '../lib/constants'
import type { CustomItem, ProbeResult, Source, StreamVariant } from '../types'
import { Modal } from './Modal'
import { useT } from '../i18n'

interface Props {
  /** The channel to measure in all its qualities. */
  streamId: number
  /** Shown in the title (the channel's name). */
  title: string
  sources: Source[]
  /** Active list: flags variants already on it. */
  listId?: number | null
  /** Opened from a list row: offer "Use this" (in-place stream swap). */
  item?: CustomItem
  onReplaced?: () => void
  onClose: () => void
}

// 'stopped' = the run was stopped while this row was being measured
type RowState = ProbeResult | 'busy' | 'stopped' | undefined
const ROW_BUSY = 'busy'
const ROW_STOPPED = 'stopped'

const SECONDS = [5, 8, 15] as const

// probe hints (rules of thumb): a picture this tall counts as UHD/2160p...
const UHD_MIN_HEIGHT = 2000
// ...and below these bitrates (kbps) a real UHD feed is unlikely -> probably upscaled
const UHD_MIN_KBPS_HEVC = 10_000
const UHD_MIN_KBPS_OTHER = 16_000
// a first byte later than this (ms) is a "slow start"
const SLOW_START_MS = 3000

/** Warnings derived from a measurement (rules of thumb, not proof). */
export function probeHints(r: ProbeResult): string[] {
  const h: string[] = []
  if (!r.ok) return h
  // 2160p at a bitrate a real UHD feed can't live with -> most likely an upscale
  const uhdFloor = r.videoCodec === 'HEVC' ? UHD_MIN_KBPS_HEVC : UHD_MIN_KBPS_OTHER
  if (r.height >= UHD_MIN_HEIGHT && r.bitrateKbps > 0 && r.bitrateKbps < uhdFloor) h.push('possibly upscaled')
  if (r.realtime > 0 && r.realtime < 1) h.push('slower than real time')
  if (r.firstByteMs > SLOW_START_MS) h.push('slow start')
  if (r.error) h.push(r.error)
  return h
}

export function formatResolution(r: ProbeResult): string {
  if (!r.width || !r.height) return '—'
  return `${r.width}×${r.height}${r.interlaced ? 'i' : 'p'}${r.bitDepth > 8 ? ` ${r.bitDepth}-bit` : ''}`
}

export function formatMbps(kbps: number): string {
  return kbps > 0 ? `${(kbps / 1000).toFixed(1)} Mbps` : '—'
}

/**
 * "Measure this channel in all qualities": finds every variant of the channel
 * (RAW / HD / UHD / 4K+ …, optionally at other providers), then measures them ONE
 * BY ONE on the backend (providers allow few concurrent connections) and fills a
 * table row per variant as each result arrives.
 */
export function QualityProbeModal({ streamId, title, sources, listId, item, onReplaced, onClose }: Props) {
  const t = useT()
  const [allSources, setAllSources] = useState(false)
  const [seconds, setSeconds] = useState<number>(DEFAULT_PROBE_SECONDS)
  const [variants, setVariants] = useState<StreamVariant[] | null>(null)
  const [results, setResults] = useState<Record<number, RowState>>({})
  const [running, setRunning] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [busyReplace, setBusyReplace] = useState(false)
  const runToken = useRef(0)

  const sourceName = (id: number) => sources.find((s) => s.id === id)?.name ?? `#${id}`

  const measure = useCallback(
    async (vs: StreamVariant[], secs: number) => {
      const token = ++runToken.current
      setResults({})
      setRunning(true)
      for (const v of vs) {
        if (runToken.current !== token) return // stopped / closed / restarted
        setResults((r) => ({ ...r, [v.streamId]: ROW_BUSY }))
        let res: ProbeResult
        try {
          res = await api.probeStream(v.streamId, secs)
        } catch (e) {
          res = {
            streamId: v.streamId, ok: false, error: e instanceof Error ? e.message : String(e),
            container: '', videoCodec: '', profile: '', width: 0, height: 0, fps: 0,
            interlaced: false, bitDepth: 0, audio: [], bitrateKbps: 0, mediaSeconds: 0,
            wallSeconds: 0, realtime: 0, firstByteMs: 0, redirects: 0, bytes: 0,
          }
        }
        if (runToken.current !== token) return
        setResults((r) => ({ ...r, [v.streamId]: res }))
      }
      if (runToken.current === token) setRunning(false)
    },
    [],
  )

  // (re)load the variants when opened or when "other providers" is toggled, then
  // start measuring straight away — that's the whole point of the dialog
  useEffect(() => {
    let cancelled = false
    setVariants(null)
    setError(null)
    runToken.current++
    setRunning(false)
    api
      .streamVariants(streamId, { allSources, listId: listId ?? 0 })
      .then((vs) => {
        if (cancelled) return
        setVariants(vs)
        if (vs.length > 0) void measure(vs, seconds)
      })
      .catch((e) => !cancelled && setError(e instanceof Error ? e.message : String(e)))
    return () => {
      cancelled = true
    }
    // seconds deliberately not a dependency: changing it doesn't re-run by itself
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [streamId, allSources, listId, measure])

  // stop measuring when the dialog closes
  useEffect(
    () => () => {
      runToken.current++
    },
    [],
  )

  function stop() {
    runToken.current++
    setRunning(false)
    // the in-flight measurement's result is discarded: don't leave it on "measuring…"
    setResults((r) => {
      const next: Record<number, RowState> = {}
      for (const [k, v] of Object.entries(r)) next[Number(k)] = v === ROW_BUSY ? ROW_STOPPED : v
      return next
    })
  }

  async function applyVariant(v: StreamVariant) {
    if (!item || !listId) return
    setBusyReplace(true)
    setError(null)
    try {
      const r = await api.replaceItems(listId, [{ itemId: item.id, streamId: v.streamId }])
      if (r.replaced === 0) {
        setError(t('Not replaced (already on the list, or another content type).'))
        return
      }
      runToken.current++
      onReplaced?.()
      onClose()
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e))
    } finally {
      setBusyReplace(false)
    }
  }

  // the measured row with the highest media bitrate gets a marker
  const bestId = (() => {
    let best = 0
    let id = 0
    for (const [k, r] of Object.entries(results))
      if (r && typeof r === 'object' && r.ok && r.bitrateKbps > best) {
        best = r.bitrateKbps
        id = Number(k)
      }
    return id
  })()

  const currentId = item ? item.streamItemId : streamId

  return (
    <Modal
      wide
      title={t('Measure quality: {name}').replace('{name}', title)}
      onClose={onClose}
      footer={
        <>
          <label className="inline">
            <input type="checkbox" checked={allSources} onChange={(e) => setAllSources(e.target.checked)} />{' '}
            {t('Also other providers')}
          </label>
          <label className="inline">
            {t('Seconds per variant')}{' '}
            <select value={seconds} onChange={(e) => setSeconds(Number(e.target.value))}>
              {SECONDS.map((s) => (
                <option key={s} value={s}>
                  {s}
                </option>
              ))}
            </select>
          </label>
          <span className="spacer" />
          {running ? (
            <button onClick={stop}>{t('Stop')}</button>
          ) : (
            <button onClick={() => variants && void measure(variants, seconds)} disabled={!variants?.length}>
              {t('Measure again')}
            </button>
          )}
          <button onClick={onClose}>{t('Close')}</button>
        </>
      }
    >
      <p className="hint">
        {t(
          'Each variant is pulled from the provider for a few seconds, one at a time. If someone is watching on the same account, a measurement can fail or interrupt them.',
        )}
      </p>
      {error && <p className="error">{error}</p>}
      {variants === null && !error && <p className="muted">{t('Looking for variants…')}</p>}
      {variants && variants.length === 0 && <p className="muted">{t('No variants found.')}</p>}
      {variants && variants.length > 0 && (
        <div className="table-wrap">
          <table className="data-table probe-table">
            <thead>
              <tr>
                <th>{t('Variant')}</th>
                <th>{t('Video')}</th>
                <th>{t('Resolution')}</th>
                <th>{t('fps')}</th>
                <th>{t('Bitrate')}</th>
                <th>{t('Audio')}</th>
                <th>{t('Start')}</th>
                <th title={t('Media seconds received per second; below 1 the player will buffer')}>
                  {t('Real time')}
                </th>
                <th>{t('Status')}</th>
                {item && listId ? <th /> : null}
              </tr>
            </thead>
            <tbody>
              {variants.map((v) => {
                const r = results[v.streamId]
                const done = r && typeof r === 'object' ? r : null
                const hints = done ? probeHints(done) : []
                const m = done && done.ok ? done : null // media cells only for a good result
                return (
                  <tr key={v.streamId} className={v.streamId === currentId ? 'row-selected' : undefined}>
                    <td>
                      <div>
                        {v.name}
                        {v.streamId === currentId && <span className="badge">{t('current')}</span>}
                        {v.onList && v.streamId !== currentId && <span className="badge">{t('on list')}</span>}
                        {done && done.ok && v.streamId === bestId && (
                          <span className="badge new" title={t('Highest bitrate')}>
                            ★
                          </span>
                        )}
                      </div>
                      <div className="muted small">
                        {sourceName(v.sourceId)}
                        {v.matchedBy === 'tvg' && ` · ${t('matched by tvg-id')}`}
                      </div>
                    </td>
                    <td>
                      {m ? m.videoCodec || '—' : ''}
                      {m?.profile && <div className="muted small">{m.profile}</div>}
                    </td>
                    <td>{m ? formatResolution(m) : ''}</td>
                    <td>{m ? (m.fps > 0 ? Number(m.fps.toFixed(2)) : '—') : ''}</td>
                    <td>{m ? formatMbps(m.bitrateKbps) : ''}</td>
                    <td className="small">
                      {m
                        ? m.audio.map((a) => (a.language ? `${a.codec} (${a.language})` : a.codec)).join(', ') || '—'
                        : ''}
                    </td>
                    <td>{m && m.firstByteMs > 0 ? `${(m.firstByteMs / 1000).toFixed(1)} s` : ''}</td>
                    <td>{m && m.realtime > 0 ? `×${m.realtime.toFixed(1)}` : ''}</td>
                    <td className="small">
                      {r === ROW_BUSY && <span className="muted">{t('measuring…')}</span>}
                      {r === ROW_STOPPED && <span className="muted">{t('stopped')}</span>}
                      {r === undefined && running && <span className="muted">{t('waiting')}</span>}
                      {done && !done.ok && <span className="error">❌ {done.error || t('failed')}</span>}
                      {done && done.ok && hints.length === 0 && '✅'}
                      {done && done.ok && hints.length > 0 && <span className="warn">⚠ {hints.map((h) => t(h)).join(' · ')}</span>}
                    </td>
                    {item && listId ? (
                      <td>
                        {v.streamId !== currentId && !v.onList && (
                          <button disabled={busyReplace} onClick={() => void applyVariant(v)}>
                            {t('Use this')}
                          </button>
                        )}
                      </td>
                    ) : null}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>
      )}
    </Modal>
  )
}
