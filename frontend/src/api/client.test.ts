import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  api,
  adminAuth,
  setUnauthorizedHandler,
  UnauthorizedError,
  TooManyRequestsError,
  parseRetryAfter,
  DEFAULT_LOCKOUT_SEC,
} from './client'

function mockFetch(res: Partial<Response> & { text: () => Promise<string> }) {
  const fn = vi.fn().mockResolvedValue(res)
  vi.stubGlobal('fetch', fn)
  return fn
}

function ok(body: unknown) {
  return { ok: true, status: 200, statusText: 'OK', text: () => Promise.resolve(JSON.stringify(body)) }
}

beforeEach(() => vi.restoreAllMocks())
afterEach(() => vi.unstubAllGlobals())

describe('api client — querystring building', () => {
  it('builds a catalog querystring from a filter', async () => {
    const fn = mockFetch(ok([]))
    await api.streams({ sourceId: 2, type: 'live', onlyNew: true, search: 'bbc', prefix: 'NL|', limit: 50, offset: 100 })
    const url = fn.mock.calls[0][0] as string
    expect(url).toContain('/api/catalog/streams?')
    expect(url).toContain('sourceId=2')
    expect(url).toContain('type=live')
    expect(url).toContain('onlyNew=1')
    expect(url).toContain('search=bbc')
    expect(url).toContain(`prefix=${encodeURIComponent('NL|')}`)
    expect(url).toContain('limit=50')
    expect(url).toContain('offset=100')
  })

  it('omits unset filter fields (and never sends includeHidden)', async () => {
    const fn = mockFetch(ok([]))
    await api.categories({ type: 'live' })
    const url = fn.mock.calls[0][0] as string
    expect(url).toContain('type=live')
    expect(url).not.toContain('sourceId')
    expect(url).not.toContain('includeHidden')
  })

  it('refreshStatus hits the status endpoint', async () => {
    const fn = mockFetch(ok([]))
    await api.refreshStatus()
    expect(fn.mock.calls[0][0]).toBe('/api/refresh/status')
  })
})

describe('api client — response handling', () => {
  it('parses a JSON body', async () => {
    mockFetch(ok({ status: 'ok' }))
    await expect(api.health()).resolves.toEqual({ status: 'ok' })
  })

  it('returns undefined for an empty body (void endpoints)', async () => {
    mockFetch({ ok: true, status: 200, statusText: 'OK', text: () => Promise.resolve('') })
    await expect(api.deleteSource(1)).resolves.toBeUndefined()
  })

  it('throws with the server message on a non-ok response (HTML stripped)', async () => {
    mockFetch({
      ok: false,
      status: 500,
      statusText: 'Internal Server Error',
      text: () => Promise.resolve('<HTML><BODY>EDatabaseError: boom</BODY></HTML>'),
    })
    await expect(api.listSources()).rejects.toThrow(/500/)
    await expect(api.listSources()).rejects.toThrow(/EDatabaseError: boom/)
  })

  it('does not throw a JSON parse error on a non-JSON success body', async () => {
    mockFetch({ ok: true, status: 200, statusText: 'OK', text: () => Promise.resolve('not json') })
    await expect(api.deleteGroup(1)).resolves.toBeUndefined()
  })
})

describe('api client — admin password', () => {
  beforeEach(() => adminAuth.clear())
  afterEach(() => {
    adminAuth.clear()
    setUnauthorizedHandler(null)
  })

  it('sends the X-Admin-Password header when a password is stored', async () => {
    adminAuth.set('s3cret')
    const fn = mockFetch(ok([]))
    await api.listSources()
    const init = fn.mock.calls[0][1] as RequestInit
    expect((init.headers as Record<string, string>)['X-Admin-Password']).toBe('s3cret')
  })

  it('always sends the X-IPTV-Client header (CSRF guard)', async () => {
    const fn = mockFetch(ok([]))
    await api.listSources()
    const init = fn.mock.calls[0][1] as RequestInit
    expect((init.headers as Record<string, string>)['X-IPTV-Client']).toBe('web')
  })

  it('omits the header when no password is set', async () => {
    const fn = mockFetch(ok([]))
    await api.listSources()
    const init = fn.mock.calls[0][1] as RequestInit
    expect((init.headers as Record<string, string>)['X-Admin-Password']).toBeUndefined()
  })

  it('throws UnauthorizedError and fires the handler on a 401', async () => {
    const onUnauth = vi.fn()
    setUnauthorizedHandler(onUnauth)
    mockFetch({ ok: false, status: 401, statusText: 'Unauthorized', text: () => Promise.resolve('') })
    await expect(api.health()).rejects.toBeInstanceOf(UnauthorizedError)
    expect(onUnauth).toHaveBeenCalled()
  })

  it('appends ?pw= to export download URLs when locked', () => {
    adminAuth.set('p w&x')
    expect(api.exportM3uUrl(3)).toBe(`/api/lists/3/export.m3u?pw=${encodeURIComponent('p w&x')}`)
  })
})

describe('api client — auth failures + lockout', () => {
  beforeEach(() => adminAuth.clear())
  afterEach(() => {
    adminAuth.clear()
    setUnauthorizedHandler(null)
  })

  it('clears the stored password on a 401 before the handler runs', async () => {
    adminAuth.set('stale')
    let seenInHandler: string | null = null
    setUnauthorizedHandler(() => {
      seenInHandler = adminAuth.get()
    })
    mockFetch({ ok: false, status: 401, statusText: 'Unauthorized', text: () => Promise.resolve('') })
    await expect(api.listSources()).rejects.toBeInstanceOf(UnauthorizedError)
    expect(adminAuth.get()).toBe('')
    expect(seenInHandler).toBe('')
  })

  it('throws TooManyRequestsError with Retry-After seconds on a 429', async () => {
    mockFetch({
      ok: false,
      status: 429,
      statusText: 'Too Many Requests',
      headers: new Headers({ 'Retry-After': '123' }),
      text: () => Promise.resolve('Too many failed logins - try again later'),
    })
    const err = await api.getConfig().catch((e) => e)
    expect(err).toBeInstanceOf(TooManyRequestsError)
    expect((err as TooManyRequestsError).retryAfterSec).toBe(123)
    expect((err as TooManyRequestsError).status).toBe(429)
  })

  it('parses Retry-After as seconds, an HTTP date, or falls back to the lockout window', () => {
    expect(parseRetryAfter('42')).toBe(42)
    const now = Date.parse('2026-01-01T00:00:00Z')
    expect(parseRetryAfter('Thu, 01 Jan 2026 00:01:00 GMT', now)).toBe(60)
    expect(parseRetryAfter(null)).toBe(DEFAULT_LOCKOUT_SEC)
    expect(parseRetryAfter('soon')).toBe(DEFAULT_LOCKOUT_SEC)
  })

  it('does not throw when localStorage is blocked', async () => {
    const spy = vi.spyOn(Storage.prototype, 'getItem').mockImplementation(() => {
      throw new Error('SecurityError')
    })
    vi.spyOn(Storage.prototype, 'setItem').mockImplementation(() => {
      throw new Error('SecurityError')
    })
    vi.spyOn(Storage.prototype, 'removeItem').mockImplementation(() => {
      throw new Error('SecurityError')
    })
    expect(adminAuth.get()).toBe('')
    expect(() => adminAuth.set('x')).not.toThrow()
    expect(() => adminAuth.clear()).not.toThrow()
    mockFetch(ok([]))
    await expect(api.listSources()).resolves.toEqual([])
    spy.mockRestore()
  })
})
