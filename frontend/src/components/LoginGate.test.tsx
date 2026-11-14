import { describe, it, expect, vi, beforeEach } from 'vitest'
import { act, render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LoginGate } from './LoginGate'

// NB: vi.mock is hoisted above imports, so the factory must be self-contained —
// it can't reference module-scope variables (they're not initialised yet).
vi.mock('../api/client', () => {
  class UnauthorizedError extends Error {}
  class TooManyRequestsError extends Error {
    retryAfterSec: number
    constructor(sec: number) {
      super('429')
      this.retryAfterSec = sec
    }
  }
  let pw = ''
  return {
    api: { health: vi.fn(), getConfig: vi.fn() },
    adminAuth: {
      get: () => pw,
      set: (v: string) => {
        pw = v
      },
      clear: () => {
        pw = ''
      },
    },
    UnauthorizedError,
    TooManyRequestsError,
  }
})
import { api, adminAuth, TooManyRequestsError, UnauthorizedError } from '../api/client'

beforeEach(() => {
  vi.clearAllMocks()
  adminAuth.clear()
})

describe('LoginGate', () => {
  it('logs in with the correct password', async () => {
    vi.mocked(api.getConfig).mockResolvedValue({} as never)
    const onAuthed = vi.fn()
    render(<LoginGate onAuthed={onAuthed} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'secret')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(onAuthed).toHaveBeenCalled()
    expect(adminAuth.get()).toBe('secret') // password kept on success
  })

  it('shows an error and clears the password on a wrong password', async () => {
    vi.mocked(api.getConfig).mockRejectedValue(new (UnauthorizedError as unknown as { new (): Error })())
    const onAuthed = vi.fn()
    render(<LoginGate onAuthed={onAuthed} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'nope')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(await screen.findByText('Incorrect password')).toBeInTheDocument()
    expect(onAuthed).not.toHaveBeenCalled()
    expect(adminAuth.get()).toBe('') // cleared so the next attempt starts fresh
  })

  it('validates against an authenticated endpoint, not the open /api/health', async () => {
    // health always answers 200 (it is not password-protected) — must not let a
    // wrong password in
    vi.mocked(api.health).mockResolvedValue({ status: 'ok' })
    vi.mocked(api.getConfig).mockRejectedValue(new (UnauthorizedError as unknown as { new (): Error })())
    const onAuthed = vi.fn()
    render(<LoginGate onAuthed={onAuthed} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'wrong')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(await screen.findByText('Incorrect password')).toBeInTheDocument()
    expect(onAuthed).not.toHaveBeenCalled()
    expect(api.getConfig).toHaveBeenCalled()
  })

  it('shows the translated lockout message on a 429 and blocks submitting', async () => {
    vi.mocked(api.getConfig).mockRejectedValue(new TooManyRequestsError(90))
    render(<LoginGate onAuthed={vi.fn()} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'secret')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(await screen.findByText('Too many failed logins. Try again in 90 s.')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Log in' })).toBeDisabled()
    expect(screen.queryByText(/try again later/)).toBeNull() // not the raw backend text
  })

  it('starts locked when the app probe already got a 429, and counts down', async () => {
    vi.useFakeTimers()
    try {
      render(<LoginGate onAuthed={vi.fn()} lockedForSec={3} />)
      expect(screen.getByText('Too many failed logins. Try again in 3 s.')).toBeInTheDocument()
      expect(screen.getByRole('button', { name: 'Log in' })).toBeDisabled()
      await act(async () => {
        vi.advanceTimersByTime(1000)
      })
      expect(screen.getByText('Too many failed logins. Try again in 2 s.')).toBeInTheDocument()
      await act(async () => {
        vi.advanceTimersByTime(2000)
      })
      expect(screen.queryByText(/Too many failed logins/)).toBeNull()
    } finally {
      vi.useRealTimers()
    }
  })
})
