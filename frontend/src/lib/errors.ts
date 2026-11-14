// API error shape + readable texts for the backend's guard responses (403 access
// block, 411/413 request body, 400 refusals). Kept out of api/client so component
// tests that mock that module still see them.

export const HTTP_BAD_REQUEST = 400
export const HTTP_FORBIDDEN = 403
export const HTTP_LENGTH_REQUIRED = 411
export const HTTP_PAYLOAD_TOO_LARGE = 413
/** The backend refuses request bodies larger than this (Content-Length) with 413. */
export const MAX_REQUEST_BODY_BYTES = 64 * 1024 * 1024

/** A non-2xx /api answer: `message` stays "<status> <detail>" (shown as-is elsewhere). */
export class ApiError extends Error {
  readonly status: number
  readonly detail: string
  constructor(status: number, detail: string) {
    super(`${status} ${detail}`)
    this.name = 'ApiError'
    this.status = status
    this.detail = detail
  }
}

const STATUS_PREFIX = /^(\d{3})\s+([\s\S]*)$/

/** The HTTP status of an API error (also from a plain "<status> <text>" Error), else 0. */
export function errorStatus(e: unknown): number {
  if (e instanceof ApiError) return e.status
  const m = STATUS_PREFIX.exec(e instanceof Error ? e.message : '')
  return m ? Number(m[1]) : 0
}

/** The backend's text without the status prefix. */
export function errorDetail(e: unknown): string {
  if (e instanceof ApiError) return e.detail
  const msg = e instanceof Error ? e.message : String(e ?? '')
  const m = STATUS_PREFIX.exec(msg)
  return (m ? m[2] : msg).trim()
}

/** Why the admin API refused this browser (HTTP 403 from the LAN / Host guard). */
export interface AccessBlock {
  /** 'lan': no admin password + a non-local client; 'host': the Host header is not allowed */
  kind: 'lan' | 'host' | 'other'
  /** the backend's own text */
  message: string
  /** the refused host name (kind 'host') */
  host?: string
}

const LAN_TEXT = /without an admin password/i
const HOST_TEXT = /^Host\s+"([^"]*)"\s+is not allowed/i

/** The access block a 403 describes, or null for any other error. */
export function accessBlock(e: unknown): AccessBlock | null {
  if (errorStatus(e) !== HTTP_FORBIDDEN) return null
  const message = errorDetail(e)
  const host = HOST_TEXT.exec(message)
  if (host) return { kind: 'host', message, host: host[1] }
  if (LAN_TEXT.test(message)) return { kind: 'lan', message }
  return { kind: 'other', message }
}

/** A readable (translated) text for an error of a save or an import. */
export function describeError(e: unknown, t: (s: string) => string): string {
  const status = errorStatus(e)
  const detail = errorDetail(e)
  switch (status) {
    case HTTP_PAYLOAD_TOO_LARGE:
      return t('Too large for the server (413): it accepts at most 64 MB per request.')
    case HTTP_LENGTH_REQUIRED:
      return t('Refused by the server (411): the request has no size (Content-Length).')
    case HTTP_BAD_REQUEST:
      return detail ? t('Refused by the server: {detail}').replace('{detail}', detail) : (e as Error).message
    case HTTP_FORBIDDEN:
      return t('Access refused by the server: {detail}').replace('{detail}', detail)
    default:
      return e instanceof Error ? e.message : String(e)
  }
}
