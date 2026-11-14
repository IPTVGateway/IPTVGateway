import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, waitFor, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { CatalogPanel } from './CatalogPanel'
import type { Category, CustomGroup, CustomList, Source, StreamItem } from '../types'

vi.mock('../api/client', () => ({
  api: {
    categories: vi.fn(),
    streams: vi.fn().mockResolvedValue([]),
    countStreams: vi.fn().mockResolvedValue({ count: 0 }),
    markCategoriesSeen: vi.fn().mockResolvedValue(undefined),
    markStreamsSeen: vi.fn().mockResolvedValue(undefined),
    newCounts: vi.fn().mockResolvedValue({ categories: 0, streams: 0 }),
    markAllSeen: vi.fn().mockResolvedValue({ categories: 0, streams: 0 }),
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
  vi.mocked(api.newCounts).mockResolvedValue({ categories: 0, streams: 0 })
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

describe('CatalogPanel — paging + prefix', () => {
  it('clamps the page when marking seen shrinks the total below the current page', async () => {
    const rows: StreamItem[] = [{ id: 21, sourceId: 2, contentType: 'live', name: 'New A', isNew: true }]
    vi.mocked(api.streams).mockResolvedValue(rows)
    vi.mocked(api.countStreams).mockResolvedValue({ count: 250 }) // 3 pages of 100
    renderPanel()
    await userEvent.click(screen.getByLabelText('Only new'))
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'new')
    await screen.findByText('Page 1 / 3')
    await userEvent.click(screen.getByRole('button', { name: 'Next ›' }))
    await userEvent.click(screen.getByRole('button', { name: 'Next ›' }))
    await screen.findByText('Page 3 / 3')
    const row = (await screen.findByText('New A')).closest('tr') as HTMLElement
    await userEvent.click(within(row).getByRole('checkbox'))
    vi.mocked(api.countStreams).mockResolvedValue({ count: 150 }) // now only 2 pages
    await userEvent.click(screen.getByRole('button', { name: 'Mark selected as seen' }))
    expect(await screen.findByText('Page 2 / 2')).toBeInTheDocument()
  })

  it('passes the Prefix filter to the groups query (prefix alone filters the groups)', async () => {
    renderPanel()
    await userEvent.type(screen.getByPlaceholderText('Prefix (e.g. NL:)'), 'NL|')
    await waitFor(() =>
      expect(vi.mocked(api.categories).mock.calls.some((c) => (c[0] as { prefix?: string })?.prefix === 'NL|')).toBe(true),
    )
    // a prefix alone keeps the groups view (no flat stream search)
    expect(api.streams).not.toHaveBeenCalled()
  })
})

describe('CatalogPanel — mirror bouquets', () => {
  const LISTS: CustomList[] = [
    { id: 1, name: 'Main', outputUsername: '', outputPassword: '', enabled: true },
    { id: 2, name: 'Kids', outputUsername: 'k', outputPassword: 'k', enabled: true, mirrorOfListId: 1 },
  ]

  async function showStreams(activeListId: number) {
    vi.mocked(api.streams).mockResolvedValue([
      { id: 31, sourceId: 2, contentType: 'live', name: 'NPO 1', isNew: false },
    ])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 1 })
    render(<CatalogPanel sources={SOURCES} lists={LISTS} groups={[]} activeListId={activeListId} />)
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'npo')
    await screen.findByText('NPO 1')
    return screen.getByText('Add to').querySelector('select') as HTMLSelectElement
  }

  it('never offers a mirror as add target', async () => {
    const target = await showStreams(1)
    expect([...target.options].map((o) => o.value)).toEqual(['', '1'])
    expect(target).toHaveValue('1')
  })

  it('an active mirror is not preselected as target', async () => {
    const target = await showStreams(2)
    expect(target).toHaveValue('')
  })
})

describe('CatalogPanel — new channels in groups', () => {
  it('shows "+N new" on a group that is not new itself but holds new channels', async () => {
    vi.mocked(api.categories).mockResolvedValue([
      { id: 1, sourceId: 2, upstreamId: 'a', contentType: 'live', name: 'Old group', isNew: false, newCount: 5 },
    ])
    renderPanel()
    const row = (await screen.findByText('Old group')).closest('li') as HTMLElement
    expect(within(row).getByText('+5 new')).toBeTruthy()
    expect(within(row).queryByText('NEW')).toBeNull()
    // the group can be marked seen (which also clears its channels server-side)
    await userEvent.click(within(row).getByTitle('Mark this group as seen'))
    expect(api.markCategoriesSeen).toHaveBeenCalledWith([1])
  })

  it('"Mark all as seen" confirms with the counts, then clears the picked source and type', async () => {
    vi.mocked(api.newCounts).mockResolvedValue({ categories: 2, streams: 30 })
    vi.mocked(api.markAllSeen).mockResolvedValue({ categories: 2, streams: 30 })
    renderPanel()
    await userEvent.click(await screen.findByRole('button', { name: 'Mark all as seen (32)' }))
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByText('Mark 30 channels and 2 groups as seen?')).toBeTruthy()
    expect(api.markAllSeen).not.toHaveBeenCalled()
    await userEvent.click(within(dialog).getByRole('button', { name: 'Mark as seen' }))
    expect(api.markAllSeen).toHaveBeenCalledWith({ sourceId: undefined, type: 'live' })
    await waitFor(() => expect(screen.queryByRole('dialog')).toBeNull())
  })
})

describe('CatalogPanel — add target group', () => {
  const LISTS: CustomList[] = [{ id: 1, name: 'Main', outputUsername: '', outputPassword: '', enabled: true }]
  const G: CustomGroup[] = [
    { id: 10, listId: 1, name: 'Sport', contentType: 'live', isFavorite: false },
    { id: 11, listId: 1, name: 'News', contentType: 'live', isFavorite: false },
  ]

  it('falls back to the upstream group when the picked group is deleted', async () => {
    vi.mocked(api.streams).mockResolvedValue([{ id: 31, sourceId: 2, contentType: 'live', name: 'NPO 1', isNew: false }])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 1 })
    const { rerender } = render(<CatalogPanel sources={SOURCES} lists={LISTS} groups={G} activeListId={1} />)
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'npo')
    const row = (await screen.findByText('NPO 1')).closest('tr') as HTMLElement
    const groupSel = document.querySelector('select.target-group') as HTMLSelectElement
    await userEvent.selectOptions(groupSel, '10')
    expect(groupSel).toHaveValue('10')
    // group 10 is deleted in the bouquet panel
    rerender(<CatalogPanel sources={SOURCES} lists={LISTS} groups={[G[1]]} activeListId={1} />)
    await waitFor(() => expect(document.querySelector('select.target-group')).toHaveValue('0'))
    await userEvent.click(within(row).getByRole('checkbox'))
    await userEvent.click(screen.getByRole('button', { name: /Add 1/ }))
    expect(api.addItems).toHaveBeenCalledWith(1, [31], 0)
  })
})

describe('CatalogPanel — failed page load', () => {
  it('clears the previous rows and the selection when a page fails to load', async () => {
    vi.mocked(api.streams).mockResolvedValue([{ id: 41, sourceId: 2, contentType: 'live', name: 'Old Row', isNew: false }])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 250 })
    renderPanel()
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'old')
    const row = (await screen.findByText('Old Row')).closest('tr') as HTMLElement
    await userEvent.click(within(row).getByRole('checkbox'))
    expect(screen.getByText('1 selected')).toBeInTheDocument()
    vi.mocked(api.streams).mockRejectedValue(new Error('500 boom'))
    await userEvent.click(screen.getByRole('button', { name: 'Next ›' }))
    expect(await screen.findByText('500 boom')).toBeInTheDocument()
    expect(screen.queryByText('Old Row')).toBeNull()
    expect(screen.getByText('0 selected')).toBeInTheDocument()
    vi.mocked(api.streams).mockResolvedValue([])
  })

  it('stays on the page that failed (no jump back to page 1) and keeps the error', async () => {
    vi.mocked(api.streams).mockResolvedValue([{ id: 42, sourceId: 2, contentType: 'live', name: 'Row', isNew: false }])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 250 })
    renderPanel()
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'row')
    await screen.findByText('Page 1 / 3')
    vi.mocked(api.countStreams).mockRejectedValue(new Error('500 count'))
    await userEvent.click(screen.getByRole('button', { name: 'Next ›' }))
    expect(await screen.findByText('500 count')).toBeInTheDocument()
    expect(screen.getByText('Page 2 / 3')).toBeInTheDocument()
    vi.mocked(api.countStreams).mockResolvedValue({ count: 0 })
  })
})

describe('CatalogPanel — mark all as seen counts', () => {
  it('re-fetches the counts when the sources change', async () => {
    const { rerender } = render(<CatalogPanel sources={SOURCES} lists={[]} groups={[]} activeListId={null} />)
    await waitFor(() => expect(api.newCounts).toHaveBeenCalledTimes(1))
    rerender(<CatalogPanel sources={[{ ...SOURCES[0] }]} lists={[]} groups={[]} activeListId={null} />)
    await waitFor(() => expect(api.newCounts).toHaveBeenCalledTimes(2))
  })

  it("never shows the previous source's counts while the new ones load", async () => {
    vi.mocked(api.newCounts).mockResolvedValue({ categories: 1, streams: 4 })
    renderPanel()
    await screen.findByRole('button', { name: 'Mark all as seen (5)' })
    vi.mocked(api.newCounts).mockReturnValue(new Promise(() => {})) // the next source's counts hang
    await userEvent.selectOptions(screen.getByDisplayValue('All sources'), '2')
    await waitFor(() => expect(api.newCounts).toHaveBeenCalledTimes(2))
    expect(screen.queryByRole('button', { name: /Mark all as seen/ })).toBeNull()
  })
})

describe('CatalogPanel — search debounce', () => {
  it('a term typed right after clearing never brings back the old one', async () => {
    vi.mocked(api.streams).mockResolvedValue([])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 0 })
    renderPanel()
    const box = screen.getByPlaceholderText('Search (contains)…')
    await userEvent.type(box, 'abc')
    await screen.findByText('Search: “abc”')
    await userEvent.clear(box)
    const callsAfterClear = vi.mocked(api.streams).mock.calls.length
    await userEvent.type(box, 'x')
    expect(screen.queryByText('Search: “abc”')).toBeNull()
    await screen.findByText('Search: “x”')
    for (const c of vi.mocked(api.streams).mock.calls.slice(callsAfterClear))
      expect((c[0] as { search?: string }).search).not.toBe('abc')
  })
})

describe('CatalogPanel — back to groups', () => {
  it('in a flat search, Back clears the search and the prefix and shows the groups', async () => {
    vi.mocked(api.streams).mockResolvedValue([{ id: 51, sourceId: 2, contentType: 'live', name: 'Hit', isNew: false }])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 1 })
    renderPanel()
    await userEvent.type(screen.getByPlaceholderText('Prefix (e.g. NL:)'), 'NL|')
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'hit')
    await screen.findByText('Hit')
    await userEvent.click(screen.getByRole('button', { name: '← Back to groups' }))
    expect(await screen.findByText('KEEP')).toBeInTheDocument()
    expect(screen.getByPlaceholderText('Search (contains)…')).toHaveValue('')
    expect(screen.getByPlaceholderText('Prefix (e.g. NL:)')).toHaveValue('')
    expect(screen.queryByRole('button', { name: '← Back to groups' })).toBeNull()
  })

  it('drilled with a search term, Back returns to the group list (not the flat search)', async () => {
    vi.mocked(api.streams).mockResolvedValue([{ id: 52, sourceId: 2, contentType: 'live', name: 'In group', isNew: false }])
    vi.mocked(api.countStreams).mockResolvedValue({ count: 1 })
    renderPanel()
    await userEvent.selectOptions(screen.getByDisplayValue('All sources'), '2')
    await userEvent.click(await screen.findByText('KEEP'))
    await screen.findByText('In group')
    await userEvent.type(screen.getByPlaceholderText('Search (contains)…'), 'in')
    await userEvent.click(screen.getByRole('button', { name: '← Back to groups' }))
    expect(await screen.findByText('KEEP')).toBeInTheDocument()
    expect(screen.queryByText(/Search: /)).toBeNull()
    expect(screen.getByPlaceholderText('Search (contains)…')).toHaveValue('')
  })
})

