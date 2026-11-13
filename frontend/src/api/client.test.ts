import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { api, adminAuth, setUnauthorizedHandler, UnauthorizedError } from './client'

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
