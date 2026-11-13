import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { SourcesPanel } from './SourcesPanel'
import type { Source, PrefixCount } from '../types'

// mock the API client the panel talks to
vi.mock('../api/client', () => {
  return {
    api: {
      listSources: vi.fn(),
      saveSource: vi.fn().mockResolvedValue({}),
      deleteSource: vi.fn().mockResolvedValue(undefined),
      refreshSource: vi.fn().mockResolvedValue(undefined),
      refreshAll: vi.fn().mockResolvedValue(undefined),
      restripPrefixes: vi.fn().mockResolvedValue({ updated: 0 }),
      sourcePrefixes: vi.fn(),
      refreshStatus: vi.fn(),
    },
  }
})

import { api } from '../api/client'

const SOURCE: Source = {
  id: 2,
  name: 'ProviderC',
  kind: 'xtream',
  url: 'http://host',
  username: 'u',
  password: 'p',
  epgUrl: '',
  enabled: true,
  contentTypes: ['live'],
  includeFilters: [],
  excludeFilters: ['AR|', 'MXC|'],
}

const PREFIXES: PrefixCount[] = [
  { prefix: 'AR|', count: 2296 },
  { prefix: 'NL|', count: 1111 },
]

beforeEach(() => {
  vi.clearAllMocks() // reset call counts between tests
  vi.mocked(api.listSources).mockResolvedValue([SOURCE])
  vi.mocked(api.sourcePrefixes).mockResolvedValue(PREFIXES)
  vi.mocked(api.refreshStatus).mockResolvedValue([])
})

describe('SourcesPanel — Edit → Exclude flow', () => {
  it('loads the saved exclude tokens AND the discovered prefixes', async () => {
    render(<SourcesPanel />)

    // source row appears, then click its Edit button
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }))

    // form switches to edit mode for #2
    expect(await screen.findByText(/Edit source #2/)).toBeInTheDocument()

    // open the Exclude modal
    await userEvent.click(screen.getByRole('button', { name: /^Exclude/ }))

    // prefixes were fetched for the edited source
    await waitFor(() => expect(api.sourcePrefixes).toHaveBeenCalledWith(2))

    // saved tokens show as chips
    const chips = [...document.querySelectorAll('.chip')].map((c) => c.textContent)
    expect(chips.some((t) => t?.includes('AR|'))).toBe(true)
    expect(chips.some((t) => t?.includes('MXC|'))).toBe(true)

    // discovered prefixes show in the picker
    const picker = document.querySelector('.prefix-picker') as HTMLElement
    expect(picker).toBeTruthy()
    expect(within(picker).getByText('NL|')).toBeInTheDocument()
  })

  it('the Exclude button label reflects the saved token count', async () => {
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }))
    // 2 saved exclude tokens
    expect(await screen.findByRole('button', { name: 'Exclude (2)' })).toBeInTheDocument()
  })

  it('a brand-new (unsaved) source shows the "save first" hint, not prefixes', async () => {
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    // open the editor in "Add" mode (no id) via the header button — not Edit
    await userEvent.click(screen.getByRole('button', { name: 'Add source' }))
    await screen.findByText('Add source', { selector: '.modal-head h3' })
    await userEvent.click(screen.getByRole('button', { name: /^Exclude/ }))
    expect(await screen.findByText(/Save the source and refresh/)).toBeInTheDocument()
    expect(api.sourcePrefixes).not.toHaveBeenCalled()
  })
})

describe('SourcesPanel — per-provider UA / Referer', () => {
  it('saves the User-Agent and Referer overrides', async () => {
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }))
    await screen.findByText(/Edit source #2/)

    await userEvent.type(screen.getByLabelText('User-Agent'), 'VLC/3.0.20 LibVLC/3.0.20')
    await userEvent.type(screen.getByLabelText('Referer'), 'http://provider.example/c/')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect(api.saveSource).toHaveBeenCalledWith(
      expect.objectContaining({
        id: 2,
        userAgent: 'VLC/3.0.20 LibVLC/3.0.20',
        referer: 'http://provider.example/c/',
      }),
    )
  })
})

describe('SourcesPanel — strip prefixes', () => {
  it('loads the saved strip prefixes and saves edited tokens as an array', async () => {
    vi.mocked(api.listSources).mockResolvedValue([{ ...SOURCE, stripPrefixes: ['NL'] }])
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }))
    await screen.findByText(/Edit source #2/)

    const field = screen.getByLabelText('Strip prefixes') as HTMLInputElement
    expect(field.value).toBe('NL')

    await userEvent.clear(field)
    await userEvent.type(field, 'NL; UK')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))

    expect(api.saveSource).toHaveBeenCalledWith(
      expect.objectContaining({ id: 2, stripPrefixes: ['NL', 'UK'] }),
    )
  })
})

describe('SourcesPanel — live ingest status', () => {
  it('shows a busy indicator and disables Refresh while a source is ingesting', async () => {
    vi.mocked(api.refreshStatus).mockResolvedValue([
      { sourceId: 2, running: true, startedUtc: '', finishedUtc: '', streams: 1234, categories: 0, programmes: 0, error: '' },
    ])
    render(<SourcesPanel />)
    const line = await screen.findByText(/Ingesting/)
    expect(line.textContent?.replace(/[.,\s]/g, '')).toContain('1234streams')
    const btn = screen.getByRole('button', { name: 'Busy…' })
    expect(btn).toBeDisabled()
  })

  it('shows a done summary with counts', async () => {
    vi.mocked(api.refreshStatus).mockResolvedValue([
      { sourceId: 2, running: false, startedUtc: '', finishedUtc: '2026-06-14T21:39:27Z', streams: 30831, categories: 96, programmes: 12, error: '' },
    ])
    render(<SourcesPanel />)
    const line = await screen.findByText(/Done:/)
    expect(line.textContent?.replace(/[.,\s]/g, '')).toContain('30831streams')
  })

  it('shows an error when an ingest failed', async () => {
    vi.mocked(api.refreshStatus).mockResolvedValue([
      { sourceId: 2, running: false, startedUtc: '', finishedUtc: '2026-06-14T21:39:27Z', streams: 0, categories: 0, programmes: 0, error: 'WinHTTP 12152' },
    ])
    render(<SourcesPanel />)
    expect(await screen.findByText(/Failed: WinHTTP 12152/)).toBeInTheDocument()
  })
})
