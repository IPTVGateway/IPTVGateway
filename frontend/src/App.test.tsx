import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ApiError } from './lib/errors'

vi.mock('./api/client', () => {
  class UnauthorizedError extends Error {}
  class TooManyRequestsError extends Error {
    retryAfterSec = 0
  }
  // the workbench panels call many more endpoints once signed in: any other api
  // function resolves to an empty list
  const fallback = (base: Record<string, unknown>) =>
    new Proxy(base, {
      get: (target, key: string) => {
        if (!(key in target)) target[key] = vi.fn().mockResolvedValue([])
        return target[key]
      },
    })
  return {
    api: fallback({
      health: vi.fn().mockResolvedValue({ status: 'ok', version: '1.0' }),
      getConfig: vi.fn(),
      plexStatus: vi.fn().mockResolvedValue({ pending: false, enabled: false, configured: false }),
      updateStatus: vi.fn(),
      listSources: vi.fn().mockResolvedValue([]),
      listLists: vi.fn().mockResolvedValue([]),
    }),
    adminAuth: { get: () => '', set: vi.fn(), clear: vi.fn() },
    setUnauthorizedHandler: vi.fn(),
    UnauthorizedError,
    TooManyRequestsError,
  }
})

import { api } from './api/client'
import { App } from './App'

beforeEach(() => {
  vi.clearAllMocks()
  // jsdom has no matchMedia (the theme follows the OS setting)
  window.matchMedia = vi.fn().mockReturnValue({
    matches: false,
    addEventListener: vi.fn(),
    removeEventListener: vi.fn(),
  }) as unknown as typeof window.matchMedia
})

describe('App — access blocked (403)', () => {
  it('shows a full-page notice for the "no admin password, LAN only" guard (not "authed")', async () => {
    const text = 'Without an admin password the admin API only answers the local network - set an admin password'
    vi.mocked(api.getConfig).mockRejectedValue(new ApiError(403, text))
    render(<App />)
    expect(await screen.findByText(text)).toBeInTheDocument()
    expect(screen.getByText(/Set an admin password/)).toBeInTheDocument()
    expect(screen.getByText(/local-network address/)).toBeInTheDocument()
    // allowedHosts does not help against the LAN guard
    expect(screen.queryByText(/allowedHosts/)).toBeNull()
    // no workbench behind it
    expect(screen.queryByText('Workbench')).toBeNull()
    expect(api.listSources).not.toHaveBeenCalled()
  })

  it('names the refused host and suggests allowedHosts', async () => {
    vi.mocked(api.getConfig).mockRejectedValue(
      new ApiError(403, 'Host "tv.example.com" is not allowed: use a LAN address'),
    )
    render(<App />)
    expect(await screen.findByText(/Host "tv.example.com" is not allowed/)).toBeInTheDocument()
    expect(screen.getByText('Or add the host “tv.example.com” to allowedHosts in config.json.')).toBeInTheDocument()
  })
})

describe('App — update notice', () => {
  const status = {
    enabled: true,
    current: '1.2.41',
    latest: '1.2.42',
    available: true,
    releaseUrl: 'https://github.com/IPTVGateway/IPTVGateway/releases/tag/v1.2.42',
    checkedUtc: '2026-11-15T12:00:00Z',
    error: '',
  }

  it('links to the release when the server found a newer version', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ proxyStreams: false } as never)
    vi.mocked(api.updateStatus).mockResolvedValue(status)
    render(<App />)
    const link = await screen.findByRole('link', { name: 'Update: v1.2.42' })
    expect(link).toHaveAttribute('href', status.releaseUrl)
    expect(link).toHaveAttribute('rel', 'noopener noreferrer')
  })

  it('shows nothing when the running version is the latest', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({ proxyStreams: false } as never)
    vi.mocked(api.updateStatus).mockResolvedValue({ ...status, latest: '1.2.41', available: false })
    render(<App />)
    await screen.findByText('Workbench')
    await vi.waitFor(() => expect(api.updateStatus).toHaveBeenCalled())
    expect(screen.queryByText(/Update: v/)).toBeNull()
  })
})
