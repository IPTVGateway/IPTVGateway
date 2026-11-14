import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ApiError } from './lib/errors'

vi.mock('./api/client', () => {
  class UnauthorizedError extends Error {}
  class TooManyRequestsError extends Error {
    retryAfterSec = 0
  }
  return {
    api: {
      health: vi.fn().mockResolvedValue({ status: 'ok', version: '1.0' }),
      getConfig: vi.fn(),
      plexStatus: vi.fn().mockResolvedValue({ pending: false, enabled: false, configured: false }),
      listSources: vi.fn().mockResolvedValue([]),
      listLists: vi.fn().mockResolvedValue([]),
    },
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
