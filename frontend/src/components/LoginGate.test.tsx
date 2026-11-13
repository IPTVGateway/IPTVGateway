import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LoginGate } from './LoginGate'

// NB: vi.mock is hoisted above imports, so the factory must be self-contained —
// it can't reference module-scope variables (they're not initialised yet).
vi.mock('../api/client', () => {
  class UnauthorizedError extends Error {}
  let pw = ''
  return {
    api: { health: vi.fn() },
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
  }
})
import { api, adminAuth, UnauthorizedError } from '../api/client'

beforeEach(() => {
  vi.clearAllMocks()
  adminAuth.clear()
})

describe('LoginGate', () => {
  it('logs in with the correct password', async () => {
    vi.mocked(api.health).mockResolvedValue({ status: 'ok' })
    const onAuthed = vi.fn()
    render(<LoginGate onAuthed={onAuthed} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'secret')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(onAuthed).toHaveBeenCalled()
    expect(adminAuth.get()).toBe('secret') // password kept on success
  })

  it('shows an error and clears the password on a wrong password', async () => {
    vi.mocked(api.health).mockRejectedValue(new (UnauthorizedError as unknown as { new (): Error })())
    const onAuthed = vi.fn()
    render(<LoginGate onAuthed={onAuthed} />)
    await userEvent.type(screen.getByPlaceholderText('Password'), 'nope')
    await userEvent.click(screen.getByRole('button', { name: 'Log in' }))
    expect(await screen.findByText('Incorrect password')).toBeInTheDocument()
    expect(onAuthed).not.toHaveBeenCalled()
    expect(adminAuth.get()).toBe('') // cleared so the next attempt starts fresh
  })
})
