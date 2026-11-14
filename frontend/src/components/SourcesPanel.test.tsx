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
  password: '', // write-only: the backend never returns it
  hasPassword: true,
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

describe('SourcesPanel — delete', () => {
  it('asks for confirmation before deleting a source; cancel keeps it', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(false)
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }))
    expect(confirm).toHaveBeenCalledWith(expect.stringContaining('ProviderC'))
    expect(api.deleteSource).not.toHaveBeenCalled()
    confirm.mockRestore()
  })

  it('deletes the source after confirming', async () => {
    const confirm = vi.spyOn(window, 'confirm').mockReturnValue(true)
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Delete' }))
    await waitFor(() => expect(api.deleteSource).toHaveBeenCalledWith(2))
    confirm.mockRestore()
  })
})

describe('SourcesPanel — write-only password', () => {
  async function openEditor() {
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByRole('button', { name: 'Edit' }))
    await screen.findByText(/Edit source #2/)
    return document.querySelector('input[type="password"]') as HTMLInputElement
  }

  it('shows "(unchanged)" and omits the password on save when not typed in', async () => {
    const pw = await openEditor()
    expect(pw).toHaveValue('')
    expect(pw).toHaveAttribute('placeholder', '(unchanged)')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    expect(vi.mocked(api.saveSource).mock.calls[0][0]).not.toHaveProperty('password')
  })

  it('sends a typed password', async () => {
    const pw = await openEditor()
    await userEvent.type(pw, 'secret')
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalledWith(expect.objectContaining({ password: 'secret' })))
  })

  it('sends clearPassword after an explicit clear, and shows it as pending', async () => {
    await openEditor()
    await userEvent.click(screen.getByRole('button', { name: 'clear' }))
    expect(screen.getByText('Will be removed on save')).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    const body = vi.mocked(api.saveSource).mock.calls[0][0]
    expect(body).toMatchObject({ clearPassword: true })
    expect(body).not.toHaveProperty('password')
  })

  it('undo of a pending clear keeps the stored password', async () => {
    await openEditor()
    await userEvent.click(screen.getByRole('button', { name: 'clear' }))
    await userEvent.click(screen.getByRole('button', { name: 'undo' }))
    expect(screen.queryByText('Will be removed on save')).toBeNull()
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    const body = vi.mocked(api.saveSource).mock.calls[0][0]
    expect(body).not.toHaveProperty('password')
    expect(body).not.toHaveProperty('clearPassword')
  })

  it('typing and deleting back to empty counts as untouched (keeps the stored one)', async () => {
    const pw = await openEditor()
    await userEvent.type(pw, 'x')
    await userEvent.clear(pw)
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    const body = vi.mocked(api.saveSource).mock.calls[0][0]
    expect(body).not.toHaveProperty('password')
    expect(body).not.toHaveProperty('clearPassword')
  })

  it('sends a masked URL back unchanged and explains the ***', async () => {
    const url = 'http://host/get.php?username=u&password=***'
    vi.mocked(api.listSources).mockResolvedValue([{ ...SOURCE, kind: 'm3u', url }])
    await openEditor()
    expect(screen.getByText(/hides a stored secret/)).toBeInTheDocument()
    await userEvent.click(screen.getByRole('button', { name: 'Save' }))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    expect(vi.mocked(api.saveSource).mock.calls[0][0]).toMatchObject({ url })
  })

  it('a quick content-type toggle never sends the (empty) password back', async () => {
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByLabelText('Movies'))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalled())
    const body = vi.mocked(api.saveSource).mock.calls[0][0]
    expect(body).not.toHaveProperty('password')
    expect(body).not.toHaveProperty('hasPassword')
    expect(body).toMatchObject({ id: 2, username: 'u', contentTypes: ['live', 'movie'] })
  })
})

describe('SourcesPanel — quick content-type toggles', () => {
  it('disables the toggles of a source while a save is busy and builds on the latest state', async () => {
    let finish: () => void = () => {}
    vi.mocked(api.saveSource).mockImplementationOnce(
      () => new Promise((res) => { finish = () => res({} as Source) }),
    )
    render(<SourcesPanel />)
    await screen.findByText('ProviderC')
    await userEvent.click(screen.getByLabelText('Movies'))
    expect(screen.getByLabelText('Series')).toBeDisabled()
    expect(screen.getByLabelText('Movies')).toBeChecked() // optimistic
    // the save landed: the server now has live + movie
    vi.mocked(api.listSources).mockResolvedValue([{ ...SOURCE, contentTypes: ['live', 'movie'] }])
    finish()
    await waitFor(() => expect(screen.getByLabelText('Series')).not.toBeDisabled())
    await userEvent.click(screen.getByLabelText('Series'))
    await waitFor(() => expect(api.saveSource).toHaveBeenCalledTimes(2))
    expect(vi.mocked(api.saveSource).mock.calls[1][0]).toMatchObject({ contentTypes: ['live', 'movie', 'series'] })
  })
})
