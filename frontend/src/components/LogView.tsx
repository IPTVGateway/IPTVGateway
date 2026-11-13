import { useEffect, useMemo, useRef, useState } from 'react'
import { api, type LogLine } from '../api/client'
import { useT } from '../i18n'

const MAX_LINES = 2000
const POLL_MS = 3000

/** Lines that point at a problem get a colour. */
export function logLevel(text: string): 'error' | 'warn' | '' {
  if (/\b(fail(ed|ure)?|error|exception|unreachable|refused|denied|timeout)\b/i.test(text)) return 'error'
  if (/\b(warn(ing)?|retry|skipped|not found|401|403|404|461)\b/i.test(text)) return 'warn'
  return ''
}

function fmtTime(iso: string): string {
  const d = new Date(iso)
  return Number.isNaN(d.getTime())
    ? ''
    : d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit', second: '2-digit' })
}

/**
 * The gateway's log in the browser: the last ~2000 lines the service keeps in
 * memory, refreshed every few seconds. Pause to read, filter on text, download.
 */
export function LogView() {
  const t = useT()
  const [lines, setLines] = useState<LogLine[]>([])
  const [paused, setPaused] = useState(false)
  const [filter, setFilter] = useState('')
  const [onlyProblems, setOnlyProblems] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const since = useRef(0)
  const box = useRef<HTMLDivElement>(null)
  const stick = useRef(true) // follow the tail unless the user scrolled up

  useEffect(() => {
    if (paused) return
    let cancelled = false
    async function poll() {
      try {
        const r = await api.logs(since.current)
        if (cancelled) return
        setError(null)
        if (r.lines.length === 0) return
        const restarted = r.lines[0].seq <= since.current
        since.current = r.next
        setLines((cur) => {
          const next = restarted ? r.lines : cur.concat(r.lines)
          return next.length > MAX_LINES ? next.slice(next.length - MAX_LINES) : next
        })
      } catch (e) {
        if (!cancelled) setError(e instanceof Error ? e.message : String(e))
      }
    }
    void poll()
    const id = setInterval(() => void poll(), POLL_MS)
    return () => {
      cancelled = true
      clearInterval(id)
    }
  }, [paused])

  const shown = useMemo(() => {
    const f = filter.trim().toLowerCase()
    return lines.filter(
      (l) => (!f || l.text.toLowerCase().includes(f)) && (!onlyProblems || logLevel(l.text) !== ''),
    )
  }, [lines, filter, onlyProblems])

  // keep the newest line in view while following the tail
  useEffect(() => {
    const el = box.current
    if (el && stick.current) el.scrollTop = el.scrollHeight
  }, [shown])

  function onScroll() {
    const el = box.current
    if (el) stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 40
  }

  function download() {
    const text = lines.map((l) => `${l.t}  ${l.text}`).join('\n') + '\n'
    const url = URL.createObjectURL(new Blob([text], { type: 'text/plain' }))
    const a = document.createElement('a')
    a.href = url
    a.download = `iptv-gateway-log-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.txt`
    a.click()
    URL.revokeObjectURL(url)
  }

  return (
    <section className="panel log-view">
      <header className="panel-head log-head">
        <h2>{t('Log')}</h2>
        <input
          className="log-filter"
          placeholder={t('Filter (e.g. timeshift, EPG, failed)…')}
          value={filter}
          onChange={(e) => setFilter(e.target.value)}
        />
        <label className="inline">
          <input type="checkbox" checked={onlyProblems} onChange={(e) => setOnlyProblems(e.target.checked)} />
          {t('Only problems')}
        </label>
        <span className="spacer" />
        <span className="muted small">
          {shown.length} / {lines.length}
        </span>
        <button onClick={() => setPaused((p) => !p)}>{paused ? t('Resume') : t('Pause')}</button>
        <button onClick={() => setLines([])}>{t('Clear view')}</button>
        <button onClick={download} disabled={lines.length === 0}>
          {t('Download')}
        </button>
      </header>
      {error && <p className="error pad">{error}</p>}
      <div className="log-lines" ref={box} onScroll={onScroll}>
        {shown.length === 0 && <p className="muted pad">{t('No log lines yet.')}</p>}
        {shown.map((l) => (
          <div key={l.seq} className={`log-line ${logLevel(l.text)}`}>
            <span className="log-time">{fmtTime(l.t)}</span>
            <span className="log-text">{l.text}</span>
          </div>
        ))}
      </div>
    </section>
  )
}
