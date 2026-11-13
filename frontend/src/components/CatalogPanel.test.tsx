import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { CatalogPanel } from './CatalogPanel'
import type { Category, Source, StreamItem } from '../types'

vi.mock('../api/client', () => ({
  api: {
    categories: vi.fn(),
    streams: vi.fn().mockResolvedValue([]),
    countStreams: vi.fn().mockResolvedValue({ count: 0 }),
    markCategoriesSeen: vi.fn().mockResolvedValue(undefined),
    markStreamsSeen: vi.fn().mockResolvedValue(undefined),
    addItems: vi.fn().mockResolvedValue({ added: 0 }),
  },
}))

import { api } from '../api/client'

const SOURCES: Source[] = [
  { id: 2, name: 'ProviderC', kind: 'xtream', url: '', enabled: true, contentTypes: ['live'] },
]
const CATS: Category[] = [
  { id: 1, sourceId: 2, upstreamId: 'a', contentType: 'live', name: 'KEEP', isNew: false },
]

beforeEach(() => {
  vi.clearAllMocks()
  vi.mocked(api.categories).mockResolvedValue(CATS)
})

function renderPanel() {
  render(
    <CatalogPanel sources={SOURCES} lists={[]} groups={[]} activeListId={null} />,
  )
}

describe('CatalogPanel — backend-only filtering', () => {
  it('never asks the backend for unfiltered data (no includeHidden) — the server always filters', async () => {
    renderPanel()
    await waitFor(() => expect(api.categories).toHaveBeenCalled())
    for (const call of vi.mocked(api.categories).mock.calls)
      expect((call[0] as Record<string, unknown>)?.includeHidden).toBeUndefined()
    // and there is no "Show filtered" control to re-enable unfiltered fetches
    expect(screen.queryByText('Show filtered')).toBeNull()
  })
})

describe('CatalogPanel — only new', () => {
  it('drops rows marked as seen from the "only new" view and re-fetches the page', async () => {
    const rows: StreamItem[] = [
      { id: 11, sourceId: 2, contentType: 'live', name: 'New One', isNew: true },
      { id: 12, sourceId: 2, contentType: 'live', name: 'New Two', isNew: true },
    ]
    vi.mocked(api.streams).mockResolvedValue(rows)
    vi.mocked(api.countStreams).mockResolvedValue({ count: 2 })
    renderPanel()
    await userEvent.click(screen.getByLabelText('Only new'))
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'new')
    const row = (await screen.findByText('New One')).closest('tr') as HTMLElement
    await userEvent.click(within(row).getByRole('checkbox'))
    // after marking, the server no longer returns the seen row
    vi.mocked(api.streams).mockResolvedValue([rows[1]])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 1 })
    const callsBefore = vi.mocked(api.streams).mock.calls.length
    await userEvent.click(screen.getByRole('button', { name: 'Mark selected as seen' }))
    expect(api.markStreamsSeen).toHaveBeenCalledWith([11])
    await waitFor(() => expect(screen.queryByText('New One')).toBeNull())
    await waitFor(() => expect(vi.mocked(api.streams).mock.calls.length).toBeGreaterThan(callsBefore))
    expect(screen.getByText('New Two')).toBeInTheDocument()
  })
})
