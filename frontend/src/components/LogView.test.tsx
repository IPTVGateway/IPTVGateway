import { describe, it, expect, vi } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { LogView, logLevel } from './LogView'

vi.mock('../api/client', () => ({
  api: {
    logs: vi.fn().mockResolvedValue({
      next: 3,
      lines: [
        { seq: 1, t: '2026-11-13T14:00:00.000Z', text: 'warm-up done in 120 ms - API open' },
        { seq: 2, t: '2026-11-13T14:00:01.000Z', text: 'Extra EPG 1 failed: timeout' },
        { seq: 3, t: '2026-11-13T14:00:02.000Z', text: '  timeshift stream 12 "NPO 1"' },
      ],
    }),
  },
}))

describe('LogView', () => {
  it('shows the service log and filters it', async () => {
    render(<LogView />)
    expect(await screen.findByText(/warm-up done/)).toBeInTheDocument()
    expect(screen.getByText(/Extra EPG 1 failed/).closest('.log-line')).toHaveClass('error')
    await userEvent.type(screen.getByPlaceholderText(/Filter/), 'timeshift')
    await waitFor(() => expect(screen.queryByText(/warm-up done/)).toBeNull())
    expect(screen.getByText(/timeshift stream 12/)).toBeInTheDocument()
  })

  it('classifies problem lines', () => {
    expect(logLevel('Source "X" failed: HTTP 461')).toBe('error')
    expect(logLevel('redirect stream 5 -> provider')).toBe('')
  })
})
