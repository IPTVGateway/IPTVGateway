import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor } from '@testing-library/react'
import { CatalogPanel } from './CatalogPanel'
import type { Category, Source } from '../types'

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
